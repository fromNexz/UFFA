<#
.SYNOPSIS
    Otimização e limpeza de disco para Windows 10/11 (64-bit) - ambiente de varejo/PDV.

.DESCRIPTION
    - Não interativo; roda como SYSTEM ou Administrador local; PowerShell 5.1 nativo.
    - Pensado para execução via:  irm <url-raw> | iex   (por isso NÃO usa 'exit' nem 'param').
    - Cada etapa tem try/catch isolado; arquivos travados são simplesmente ignorados.
    - Nunca encerra processos. Nunca toca em pastas de PostgreSQL, CISS, FrCaixa ou RustDesk.
    - Linha final padronizada:
      [OTM_RESULT] STATUS=OK | LIBERADO_MB=XXXX | LIVRE_ATUAL_GB=XXXX | TEMPO_SEG=XX
      STATUS: OK | PARCIAL (alguma etapa falhou) | TIMEOUT (prazo estourou) |
              SEM_PRIVILEGIO | JA_EXECUTANDO | ERRO
#>

function Invoke-OtmOtimizar {

    $ErrorActionPreference = 'Continue'
    $ProgressPreference    = 'SilentlyContinue'
    $inv = [Globalization.CultureInfo]::InvariantCulture

    # ------------------------------------------------------------------
    # CONFIGURAÇÃO (ajuste aqui, sem mexer no restante)
    # ------------------------------------------------------------------
    $Cfg = @{
        Unidade           = 'C'    # Unidade a limpar/medir
        LimiteSeg         = 900    # Timeout global preventivo (segundos)
        IdadeTempDias     = 1      # Temp (sistema/usuários): só apaga o que tem mais de N dias
        IdadePrefetchDias = 30     # Prefetch: só arquivos .pf obsoletos
        IdadeLogsDias     = 7      # Dumps de crash e logs de erro
        TrimTimeoutSeg    = 120    # Timeout do TRIM
        ServicoTimeoutSeg = 30     # Timeout para parar/iniciar o wuauserv
        LimparStandby     = $true  # Purga a lista standby de memória (ver observações)
        PastaLog          = (Join-Path $env:ProgramData 'OTM')
    }

    # Pastas que NUNCA são tocadas (banco, CISS/FrCaixa, acesso remoto)
    $Protegidos = '(?i)\\(postgres[^\\]*|pgsql|pg_[^\\]*|ciss[^\\]*|frcaixa[^\\]*|rustdesk[^\\]*)(\\|$)'

    $Estado = @{
        Cron    = [Diagnostics.Stopwatch]::StartNew()
        Falhas  = 0
        Timeout = $false
        LogArq  = (Join-Path $Cfg.PastaLog 'otimizar.log')
    }

    # ------------------------------------------------------------------
    # FUNÇÕES AUXILIARES
    # ------------------------------------------------------------------

    # Log no console (stdout) e em arquivo (com tratamento silencioso de erro)
    function Write-Log {
        param([string]$Msg, [string]$Nivel = 'INFO', [switch]$Cru)
        if ($Cru) { $linha = $Msg }
        else { $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Msg }
        Write-Host $linha
        try { Add-Content -LiteralPath $Estado.LogArq -Value $linha -Encoding UTF8 -ErrorAction Stop } catch { }
    }

    # Verifica se o prazo global estourou
    function Test-Prazo {
        if ($Estado.Cron.Elapsed.TotalSeconds -ge $Cfg.LimiteSeg) { $Estado.Timeout = $true; return $true }
        return $false
    }

    # Espaço livre atual na unidade (bytes)
    function Get-LivreBytes {
        $di = New-Object IO.DriveInfo ($Cfg.Unidade)
        return [long]$di.AvailableFreeSpace
    }

    function Format-MB([long]$Bytes) { return ([math]::Round($Bytes / 1MB, 2)).ToString('0.00', $inv) + ' MB' }

    # Emite a linha final padronizada
    function Write-Resultado {
        param([string]$Status, [long]$DifBytes, [long]$LivreBytes)
        $mb    = ([math]::Round($DifBytes / 1MB, 0)).ToString('0', $inv)
        $gb    = ([math]::Round($LivreBytes / 1GB, 2)).ToString('0.00', $inv)
        $tempo = [int][math]::Round($Estado.Cron.Elapsed.TotalSeconds)
        $l = '[OTM_RESULT] STATUS={0} | LIBERADO_MB={1} | LIVRE_ATUAL_GB={2} | TEMPO_SEG={3}' -f $Status, $mb, $gb, $tempo
        Write-Log $l -Cru
    }

    # Executa uma etapa isolada: falha numa etapa nunca derruba as demais
    function Invoke-Etapa {
        param([string]$Nome, [scriptblock]$Bloco)
        if (Test-Prazo) { Write-Log "Etapa '$Nome' ignorada: prazo global excedido." 'WARN'; return }
        Write-Log ">> $Nome"
        try { & $Bloco | Out-Null }
        catch {
            $Estado.Falhas++
            Write-Log "Falha na etapa '$Nome': $($_.Exception.Message)" 'ERRO'
        }
    }

    # Remove arquivos de uma pasta (varredura iterativa, sem seguir junctions/symlinks).
    # Arquivos travados/em uso são ignorados em silêncio. Retorna bytes removidos.
    function Remove-Conteudo {
        param(
            [string]$Raiz,
            [int]$IdadeDias = 0,
            [string[]]$Incluir = @('*'),
            [string[]]$Excluir = @(),
            [bool]$Recursivo = $true,
            [bool]$RemoverVazias = $true
        )
        [long]$liberado = 0
        if (-not [IO.Directory]::Exists($Raiz)) { return $liberado }
        if ($Raiz -match $Protegidos) { return $liberado }

        $limite   = (Get-Date).AddDays(-$IdadeDias)
        $pilha    = New-Object 'System.Collections.Generic.Stack[string]'
        $visitadas = New-Object 'System.Collections.Generic.List[string]'
        $datas    = @{}
        $pilha.Push($Raiz)

        while ($pilha.Count -gt 0) {
            if (Test-Prazo) { break }
            $dir = $pilha.Pop()
            if ($dir -match $Protegidos) { continue }
            try { $di = New-Object IO.DirectoryInfo $dir } catch { continue }
            $visitadas.Add($dir)
            $datas[$dir] = $di.LastWriteTime

            # Arquivos da pasta
            $arquivos = @()
            try { $arquivos = $di.GetFiles() } catch { }
            foreach ($f in $arquivos) {
                try {
                    if ($f.LastWriteTime -gt $limite) { continue }
                    if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $ok = $false
                    foreach ($p in $Incluir) { if ($f.Name -like $p) { $ok = $true; break } }
                    if (-not $ok) { continue }
                    foreach ($p in $Excluir) { if ($f.Name -like $p) { $ok = $false; break } }
                    if (-not $ok) { continue }
                    $tam = $f.Length
                    if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                    $f.Delete()                     # falha se estiver em uso -> ignorado
                    $liberado += $tam
                } catch { }
            }

            # Subpastas (ignora junctions/symlinks para nunca sair da árvore)
            if ($Recursivo) {
                $subs = @()
                try { $subs = $di.GetDirectories() } catch { }
                foreach ($s in $subs) {
                    if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $pilha.Push($s.FullName)
                }
            }
        }

        # Remove pastas que ficaram vazias (das mais profundas para as mais rasas)
        if ($RemoverVazias -and $Recursivo) {
            $visitadas.Reverse()
            foreach ($v in $visitadas) {
                if ($v -eq $Raiz) { continue }
                try {
                    if ($datas[$v] -gt $limite) { continue }
                    $d = New-Object IO.DirectoryInfo $v
                    if ($d.GetFileSystemInfos().Length -eq 0) { $d.Delete() }
                } catch { }
            }
        }
        return $liberado
    }

    # Código nativo (P/Invoke) para purgar a standby list de memória
    $codigoCs = @'
using System;
using System.Runtime.InteropServices;
public static class OtmNative {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool all, ref TokPriv1Luid ns, int len, IntPtr prev, IntPtr rlen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")]    static extern int NtSetSystemInformation(int cls, IntPtr info, int len);
    public static int PurgeStandby() {
        IntPtr tok = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, ref tok)) return -1;
        TokPriv1Luid tp = new TokPriv1Luid(); tp.Count = 1; tp.Attr = 2;
        LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", ref tp.Luid);
        AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(tok);
        IntPtr p = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(p, 4); return NtSetSystemInformation(80, p, 4); }   // MemoryPurgeStandbyList
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@

    # ------------------------------------------------------------------
    # PRÉ-CHECAGENS
    # ------------------------------------------------------------------
    try {
        if (-not (Test-Path -LiteralPath $Cfg.PastaLog)) { New-Item -ItemType Directory -Path $Cfg.PastaLog -Force | Out-Null }
        if ((Test-Path -LiteralPath $Estado.LogArq) -and ((Get-Item -LiteralPath $Estado.LogArq).Length -gt 1MB)) {
            Remove-Item -LiteralPath $Estado.LogArq -Force -ErrorAction SilentlyContinue   # rotação simples
        }
    } catch { }

    # Prioridade baixa para não competir com PDV/PostgreSQL
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }

    # Precisa ser SYSTEM ou Administrador
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $ehAdmin = $id.IsSystem -or (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $ehAdmin) {
        Write-Log 'Execute como SYSTEM ou Administrador.' 'ERRO'
        $l = 0; try { $l = Get-LivreBytes } catch { }
        Write-Resultado -Status 'SEM_PRIVILEGIO' -DifBytes 0 -LivreBytes $l
        return
    }

    # Evita duas execuções simultâneas (monitoramento disparando em duplicidade)
    $mutex = New-Object Threading.Mutex($false, 'Global\OTM_Otimizar_PS1')
    $temMutex = $false
    try { $temMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $temMutex = $true }
    if (-not $temMutex) {
        Write-Log 'Ja existe outra execucao em andamento.' 'WARN'
        $l = 0; try { $l = Get-LivreBytes } catch { }
        Write-Resultado -Status 'JA_EXECUTANDO' -DifBytes 0 -LivreBytes $l
        $mutex.Dispose()
        return
    }

    [long]$livreInicial = 0
    $statusFinal = 'OK'

    try {
        Write-Log "Inicio em $env:COMPUTERNAME como $($id.Name)"

        # --------------------------------------------------------------
        # 1) MEDIÇÃO INICIAL
        # --------------------------------------------------------------
        Write-Log '>> Medicao inicial'
        try {
            $livreInicial = Get-LivreBytes
            Write-Log ("Livre inicial: {0} ({1} bytes)" -f (Format-MB $livreInicial), $livreInicial)
        } catch {
            $Estado.Falhas++
            Write-Log "Falha na medicao inicial: $($_.Exception.Message)" 'ERRO'
        }

        # --------------------------------------------------------------
        # 2) TEMPORÁRIOS DO SISTEMA
        # --------------------------------------------------------------
        Invoke-Etapa 'Windows\Temp' {
            $b = Remove-Conteudo -Raiz (Join-Path $env:SystemRoot 'Temp') -IdadeDias $Cfg.IdadeTempDias
            Write-Log ("Windows\Temp: {0}" -f (Format-MB $b))
        }

        Invoke-Etapa 'Windows\Prefetch (obsoletos)' {
            $b = Remove-Conteudo -Raiz (Join-Path $env:SystemRoot 'Prefetch') -IdadeDias $Cfg.IdadePrefetchDias `
                 -Incluir @('*.pf') -Recursivo $false -RemoverVazias $false
            Write-Log ("Prefetch: {0}" -f (Format-MB $b))
        }

        Invoke-Etapa 'Dumps de crash e logs de erro' {
            $d = $Cfg.IdadeLogsDias
            $alvos = @(
                @{ P = (Join-Path $env:SystemRoot 'Minidump');                     I = @('*.dmp') },
                @{ P = (Join-Path $env:SystemRoot 'LiveKernelReports');            I = @('*.dmp','*.etl') },
                @{ P = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); I = @('*') },
                @{ P = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue');   I = @('*') },
                @{ P = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp');          I = @('*') },
                @{ P = (Join-Path $env:SystemRoot 'Logs\CBS');                     I = @('*.log','*.cab') },
                @{ P = (Join-Path $env:SystemRoot 'Logs\WindowsUpdate');           I = @('*.etl') }
            )
            # CrashDumps por usuário
            $usuarios = Get-ChildItem -LiteralPath ($Cfg.Unidade + ':\Users') -Directory -Force -ErrorAction SilentlyContinue
            foreach ($u in $usuarios) {
                if ($u.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $alvos += @{ P = (Join-Path $u.FullName 'AppData\Local\CrashDumps'); I = @('*.dmp') }
            }
            [long]$tot = 0
            foreach ($a in $alvos) {
                try { $tot += Remove-Conteudo -Raiz $a.P -IdadeDias $d -Incluir $a.I } catch { }
            }
            # Dump completo de memória
            try {
                $mem = Get-Item -LiteralPath (Join-Path $env:SystemRoot 'MEMORY.DMP') -Force -ErrorAction Stop
                if ($mem.LastWriteTime -lt (Get-Date).AddDays(-$d)) { $t = $mem.Length; $mem.Delete(); $tot += $t }
            } catch { }
            Write-Log ("Dumps/logs: {0}" -f (Format-MB $tot))
        }

        # --------------------------------------------------------------
        # 3) TEMPORÁRIOS DE USUÁRIOS
        # --------------------------------------------------------------
        Invoke-Etapa 'Temp de usuarios' {
            $pastas = New-Object 'System.Collections.Generic.List[string]'
            $usuarios = Get-ChildItem -LiteralPath ($Cfg.Unidade + ':\Users') -Directory -Force -ErrorAction SilentlyContinue
            foreach ($u in $usuarios) {
                if ($u.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # 'All Users', 'Default User'
                $pastas.Add((Join-Path $u.FullName 'AppData\Local\Temp'))
            }
            $pastas.Add((Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\Temp'))
            $pastas.Add((Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Temp'))
            [long]$tot = 0
            foreach ($p in $pastas) {
                try { $tot += Remove-Conteudo -Raiz $p -IdadeDias $Cfg.IdadeTempDias } catch { }
            }
            Write-Log ("Temp de usuarios: {0}" -f (Format-MB $tot))
        }

        # --------------------------------------------------------------
        # 4) LIXEIRA DO SISTEMA (C:\$Recycle.Bin) - compatível com SYSTEM
        # --------------------------------------------------------------
        Invoke-Etapa 'Lixeira (C:\$Recycle.Bin)' {
            $raiz = '{0}:\$Recycle.Bin' -f $Cfg.Unidade
            [long]$tot = 0
            $sids = @()
            try { $sids = (New-Object IO.DirectoryInfo $raiz).GetDirectories() } catch { }
            foreach ($s in $sids) {
                try { $tot += Remove-Conteudo -Raiz $s.FullName -IdadeDias 0 -Excluir @('desktop.ini') } catch { }
            }
            Write-Log ("Lixeira: {0}" -f (Format-MB $tot))
        }

        # --------------------------------------------------------------
        # 5) CACHE DO WINDOWS UPDATE (SoftwareDistribution\Download)
        # --------------------------------------------------------------
        Invoke-Etapa 'Windows Update cache' {
            $svc = Get-Service -Name 'wuauserv' -ErrorAction Stop
            $estavaRodando = ($svc.Status -eq 'Running')

            # Não mexe se houver instalação de atualização em andamento
            if (Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue) {
                Write-Log 'TiWorker ativo (servicing em andamento): etapa ignorada.' 'WARN'
                return
            }
            $parou = $true
            try {
                if ($estavaRodando) {
                    Stop-Service -Name 'wuauserv' -Force -ErrorAction Stop
                    $svc.Refresh()
                    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($Cfg.ServicoTimeoutSeg))
                }
                $svc.Refresh()
                $parou = ($svc.Status -eq 'Stopped')
                if ($parou) {
                    $b = Remove-Conteudo -Raiz (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -IdadeDias 0
                    Write-Log ("SoftwareDistribution\Download: {0}" -f (Format-MB $b))
                } else {
                    Write-Log 'wuauserv nao parou no prazo: limpeza ignorada.' 'WARN'
                }
            }
            finally {
                # Restaura o estado original do serviço
                if ($estavaRodando) {
                    try { Start-Service -Name 'wuauserv' -ErrorAction Stop } catch { Write-Log "Nao foi possivel reiniciar wuauserv: $($_.Exception.Message)" 'WARN' }
                }
            }
        }

        # --------------------------------------------------------------
        # 6) TRIM (somente SSD, sem desfragmentação)
        # --------------------------------------------------------------
        Invoke-Etapa 'TRIM (SSD)' {
            $part  = Get-Partition -DriveLetter $Cfg.Unidade -ErrorAction Stop
            $disco = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber } | Select-Object -First 1
            $tipo  = if ($disco) { [string]$disco.MediaType } else { 'Desconhecido' }
            if ($tipo -ne 'SSD') { Write-Log "Midia '$tipo': TRIM ignorado." ; return }

            # Roda em job para poder aplicar timeout
            $job = Start-Job -ScriptBlock {
                param($letra)
                Optimize-Volume -DriveLetter $letra -ReTrim -Verbose:$false -ErrorAction Stop | Out-Null
            } -ArgumentList $Cfg.Unidade
            try {
                if (Wait-Job -Job $job -Timeout $Cfg.TrimTimeoutSeg) {
                    Receive-Job -Job $job -ErrorAction Stop | Out-Null
                    Write-Log 'TRIM concluido.'
                } else {
                    Stop-Job -Job $job -ErrorAction SilentlyContinue
                    Write-Log 'TRIM excedeu o timeout e foi interrompido.' 'WARN'
                }
            }
            finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }

        # --------------------------------------------------------------
        # 7) MEMÓRIA (GC + standby list). Não encerra nenhum processo.
        # --------------------------------------------------------------
        Invoke-Etapa 'Memoria' {
            $antes = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory   # KB
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
            if ($Cfg.LimparStandby) {
                if (-not ('OtmNative' -as [type])) { Add-Type -TypeDefinition $codigoCs -ErrorAction Stop }
                $nt = [OtmNative]::PurgeStandby()
                if ($nt -ne 0) { Write-Log ('Purga de standby retornou NTSTATUS=0x{0:X8}' -f $nt) 'WARN' }
            }
            Start-Sleep -Milliseconds 500
            $depois = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory
            Write-Log ("RAM livre/disponivel: {0} MB -> {1} MB" -f [math]::Round($antes/1024), [math]::Round($depois/1024))
        }
    }
    catch {
        $Estado.Falhas++
        $statusFinal = 'ERRO'
        Write-Log "Erro inesperado: $($_.Exception.Message)" 'ERRO'
    }
    finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }

    # ------------------------------------------------------------------
    # 8) MEDIÇÃO FINAL E RESUMO
    # ------------------------------------------------------------------
    [long]$livreFinal = 0
    try { $livreFinal = Get-LivreBytes } catch { Write-Log 'Falha ao medir espaco final.' 'ERRO'; $Estado.Falhas++ }
    [long]$dif = $livreFinal - $livreInicial     # pode ser negativo se algo gravou em disco durante a execucao

    if     ($statusFinal -eq 'ERRO')  { }
    elseif ($Estado.Timeout)          { $statusFinal = 'TIMEOUT' }
    elseif ($Estado.Falhas -gt 0)     { $statusFinal = 'PARCIAL' }

    Write-Log '----------------------------------------'
    Write-Log ("Livre inicial : {0}" -f (Format-MB $livreInicial))
    Write-Log ("Livre final   : {0}" -f (Format-MB $livreFinal))
    Write-Log ("Liberado      : {0} bytes = {1} MB = {2} GB" -f $dif, ([math]::Round($dif/1MB,2)).ToString('0.00',$inv), ([math]::Round($dif/1GB,3)).ToString('0.000',$inv))
    Write-Log '----------------------------------------'
    Write-Resultado -Status $statusFinal -DifBytes $dif -LivreBytes $livreFinal
}

# Execução (envolvida em try/catch para a saída nunca quebrar o processo chamador)
try { Invoke-OtmOtimizar } catch { Write-Host "[OTM_RESULT] STATUS=ERRO | LIBERADO_MB=0 | LIVRE_ATUAL_GB=0 | TEMPO_SEG=0" }
