#requires -Version 5.1
[CmdletBinding()]
param([switch]$Aplicar)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Identidades e executaveis de negocio NAO sao removidos. Nenhum comando de rede.
$script:RaizesAntigas = @('C:\infra-monitor', 'C:\ProgramData\InfraMonitor')

function Test-ScriptAntigo([string]$Texto) {
    foreach ($raiz in $script:RaizesAntigas) {
        $arquivo = [regex]::Escape($raiz) + '\\(?:bin\\|agent\\)?(?:agent|collect|watchdog)\.ps1'
        # Apenas invocacao direta por -File. Nao confundir leitura/edicao de um script com sua execucao.
        if ($Texto -match ('(?i)(?:^|\s)-File\s+(?:\\?["''])?' + $arquivo + '(?=\\?["'']|\s|$)')) { return $true }
    }
    return $false
}
function Test-WrapperAntigo([string]$Texto) {
    foreach ($raiz in $script:RaizesAntigas) {
        $arquivo = [regex]::Escape($raiz) + '\\bin\\agent\.cmd'
        if ($Texto -match ('(?i)(?:^|\s)/c\s+(?:\\?["'']){0,2}' + $arquivo + '(?=\\?["'']|\s|$)')) { return $true }
    }
    return $false
}
function Test-ServicoAntigo($Servico, [string]$Aplicacao, [string]$Argumentos) {
    # FrCaixaMonitor e protegido explicitamente, inclusive em registros com nomes/caminhos mistos.
    foreach ($campo in @('Name','DisplayName','PathName')) {
        if ($Servico.PSObject.Properties[$campo] -and [string]$Servico.$campo -match '(?i)frcaixa|(?:^|[\\/])monitor\.exe(?:[\"\s]|$)') { return $false }
    }
    if ($Aplicacao -match '(?i)frcaixa|(?:^|[\\/])monitor\.exe$') { return $false }
    # O nome do servico sozinho NAO autoriza remover uma instalacao nova.
    $linha = [string]$Servico.PathName
    if (Test-WrapperAntigo $linha) { return $true }
    if ($linha -match '(?i)(?:powershell|pwsh)(?:\.exe)?["\s]' -and (Test-ScriptAntigo $linha)) { return $true }
    if ($linha -match '(?i)(?:^|[\\"\s])nssm\.exe(?:["\s]|$)' -and $Aplicacao -match '(?i)(?:^|\\)(?:powershell|pwsh)\.exe$' -and (Test-ScriptAntigo $Argumentos)) { return $true }
    return $false
}
function Test-TarefaAntiga($Tarefa) {
    if ($Tarefa.PSObject.Properties['TaskName'] -and [string]$Tarefa.TaskName -match '(?i)frcaixa') { return $false }
    $acoes = @($Tarefa.Actions)
    if ($acoes.Count -ne 1) { return $false }
    $acao = $acoes[0]
    if (!$acao.PSObject.Properties['Execute']) { return $false }
    $exe = [string]$acao.Execute
    $argumentos = [string]$acao.Arguments
    if ($exe -match '(?i)(?:^|\\)(?:powershell|pwsh)(?:\.exe)?$') { return (Test-ScriptAntigo $argumentos) }
    if ($exe -match '(?i)(?:^|\\)cmd(?:\.exe)?$') { return (Test-WrapperAntigo $argumentos) }
    return $false
}
function Test-TarefaAtrasada($Tarefa, [bool]$PrincipalProtegida) {
    if ($PrincipalProtegida -or $Tarefa.TaskPath -ne '\' -or $Tarefa.TaskName -ne 'InfraMonitorDelayedStart') { return $false }
    $acoes=@($Tarefa.Actions)
    if ($acoes.Count -ne 1 -or !$acoes[0].PSObject.Properties['Execute']) { return $false }
    if ([string]$acoes[0].Execute -notmatch '(?i)(?:^|\\)schtasks(?:\.exe)?$') { return $false }
    # Exatamente o relancamento criado pelo install.bat do ZIP, sem acoes adicionais.
    return ([string]$acoes[0].Arguments -match '(?i)^\s*/Run\s+/TN\s+(?:\\?["''])?\\?InfraMonitorAgent(?:\\?["''])?\s*$')
}
function Get-ServicosAntigos {
    foreach ($servico in @(Get-CimInstance Win32_Service)) {
        # Servicos de aplicativos de negocio nunca sao alvos, mesmo que seus nomes contenham monitor.
        if ($servico.Name -match '(?i)frcaixa' -or $servico.DisplayName -match '(?i)frcaixa') { continue }
        $app='';$argsLocal=''
        if ($servico.PathName -match '(?i)nssm\.exe') {
            $chave='HKLM:\SYSTEM\CurrentControlSet\Services\'+$servico.Name+'\Parameters'
            if (Test-Path -LiteralPath $chave) {
                $p=Get-ItemProperty -LiteralPath $chave
                if ($p.PSObject.Properties['Application']) { $app=[string]$p.Application }
                if ($p.PSObject.Properties['AppParameters']) { $argsLocal=[string]$p.AppParameters }
            }
        }
        if (Test-ServicoAntigo $servico $app $argsLocal) { $servico }
        elseif ($servico.Name -eq 'InfraMonitorAgent') { Write-Warning 'InfraMonitorAgent existe, mas nao aponta para um agente antigo reconhecido. Preservado.' }
    }
}
function Get-TarefasAntigas {
    $todas=@(Get-ScheduledTask)
    $principal=@($todas | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq 'InfraMonitorAgent' })
    $protegida=$principal.Count -gt 0 -and !(Test-TarefaAntiga $principal[0])
    foreach ($tarefa in $todas) {
        if ((Test-TarefaAntiga $tarefa) -or (Test-TarefaAtrasada $tarefa $protegida)) { $tarefa }
    }
}
function Get-ProcessosAntigos {
    $filtro="Name='powershell.exe' OR Name='pwsh.exe' OR Name='cmd.exe'"
    foreach ($p in @(Get-CimInstance Win32_Process -Filter $filtro)) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        if (($p.Name -match '(?i)^(powershell|pwsh)\.exe$' -and (Test-ScriptAntigo ([string]$p.CommandLine))) -or ($p.Name -ieq 'cmd.exe' -and (Test-WrapperAntigo ([string]$p.CommandLine)))) { $p }
    }
}
function Protect-Backup([string]$Pasta) {
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identidade=New-Object Security.Principal.SecurityIdentifier($sid)
        $regra=[Security.AccessControl.FileSystemAccessRule]::new($identidade,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($regra)
    }
    Set-Acl -LiteralPath $Pasta -AclObject $acl
}
function Stop-ProcessoAntigo($Registro) {
    $processo=$null
    try {
        $processo=Get-Process -Id ([int]$Registro.ProcessId) -ErrorAction Stop
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { return }
    try {
        # Abrir o handle fixa a identidade do processo; nao encerrar um PID reciclado.
        if ($processo.Handle -eq [IntPtr]::Zero) { throw 'Nao foi possivel abrir o processo.' }
        $atual=Get-CimInstance Win32_Process -Filter ("ProcessId="+[int]$Registro.ProcessId)
        if (!$atual) { return }
        if ($atual.CreationDate -ne $Registro.CreationDate -or $atual.CommandLine -cne $Registro.CommandLine) { throw 'Processo mudou durante a verificacao; preservado.' }
        if (!(Test-ScriptAntigo ([string]$atual.CommandLine)) -and !(Test-WrapperAntigo ([string]$atual.CommandLine))) { throw 'Vinculo do processo nao confirmado.' }
        $processo.Kill()
        if (!$processo.WaitForExit(10000)) { throw 'Processo nao encerrou no prazo.' }
        Write-Host ('Processo antigo encerrado: PID '+$Registro.ProcessId)
    } finally { $processo.Dispose() }
}

# Permite testes das regras de identificacao sem executar qualquer operacao de remocao.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($env:OS -ne 'Windows_NT') { throw 'Execute no Windows, em PowerShell como administrador.' }
$identidade=[Security.Principal.WindowsIdentity]::GetCurrent()
$administrador=New-Object Security.Principal.WindowsPrincipal($identidade)
if (!$administrador.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra PowerShell como administrador.' }

$servicos=@(Get-ServicosAntigos)
$tarefas=@(Get-TarefasAntigas)
$processos=@(Get-ProcessosAntigos)
Write-Host '=== Agente antigo identificado ==='
Write-Host ('Servicos: '+$servicos.Count+' | Tarefas: '+$tarefas.Count+' | Processos: '+$processos.Count)
foreach ($s in $servicos) { Write-Host ('Servico: '+$s.Name) }
foreach ($t in $tarefas) { Write-Host ('Tarefa: '+$t.TaskPath+$t.TaskName) }
foreach ($p in $processos) { Write-Host ('Processo: '+$p.Name+' PID='+$p.ProcessId) }
if (!$Aplicar) { Write-Host 'Somente consulta. Para desinstalar: execute este mesmo arquivo com -Aplicar.';return }
if ($servicos.Count+$tarefas.Count+$processos.Count -eq 0) { Write-Host 'Nenhum componente antigo reconhecido. Nenhuma alteracao realizada.';return }

$backup=Join-Path $env:ProgramData ('InfraMonitor-Remocao-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
[void][IO.Directory]::CreateDirectory($backup)
Protect-Backup $backup
Write-Host ('Backup de inicializacao: '+$backup)
$utf8=[Text.UTF8Encoding]::new($true)

# Backup de TODAS as configuracoes de inicializacao antes de desativar qualquer uma.
$i=0
foreach ($t in $tarefas) {
    $i++
    $xml=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath
    [IO.File]::WriteAllText((Join-Path $backup ('tarefa-'+$i+'.xml')),$xml,$utf8)
}
$i=0
foreach ($s in $servicos) {
    $i++
    & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\'+$s.Name) (Join-Path $backup ('servico-'+$i+'.reg')) /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Backup do servico falhou. Nenhuma remocao iniciada.' }
}
$resumo=@{servicos=@($servicos|Select-Object Name,State,StartMode);tarefas=@($tarefas|Select-Object TaskName,TaskPath,State);processos=@($processos|Select-Object Name,ProcessId);pastas_preservadas=$script:RaizesAntigas}
[IO.File]::WriteAllText((Join-Path $backup 'inventario.json'),(ConvertTo-Json -InputObject $resumo -Depth 8),$utf8)

# Desativar watchdog/relancadores ANTES de parar o coletor.
foreach ($t in $tarefas) { Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null }
foreach ($s in $servicos) { Set-Service -Name $s.Name -StartupType Disabled }
foreach ($t in $tarefas) { Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath }
foreach ($s in $servicos) {
    $controlador=Get-Service -Name $s.Name
    try {
        if ($controlador.Status -ne 'Stopped') {
            try { $controlador.Stop();$controlador.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)) }
            catch { Write-Warning ('Parada ainda pendente: '+$s.Name+'. Verificando processos do agente.') }
        }
    } finally { $controlador.Dispose() }
}
# Reenumerar apos desativar inicializacoes; inclui filhos criados por um watchdog em encerramento.
for ($tentativa=0;$tentativa -lt 3;$tentativa++) {
    $restantes=@(Get-ProcessosAntigos)
    if (!$restantes.Count) { break }
    foreach ($p in $restantes) { Stop-ProcessoAntigo $p }
    Start-Sleep -Seconds 1
}
foreach ($t in $tarefas) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }
foreach ($s in $servicos) {
    $atual=Get-Service -Name $s.Name
    if ($atual.Status -ne 'Stopped') { throw ('Servico ainda ativo: '+$s.Name+'. Mantido desabilitado. Backup: '+$backup) }
    $atual.Dispose()
    & sc.exe delete $s.Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Falha na exclusao do servico '+$s.Name+'. Backup: '+$backup) }
}
Start-Sleep -Seconds 2
$sv=@(Get-ServicosAntigos);$ta=@(Get-TarefasAntigas);$pr=@(Get-ProcessosAntigos)
if ($sv.Count+$ta.Count+$pr.Count -gt 0) { throw ('Ainda existem componentes antigos ou servico marcado para exclusao. Feche services.msc e verifique novamente. Backup: '+$backup) }
Write-Host 'Concluido: servicos, tarefas e processos antigos reconhecidos removidos.'
Write-Host ('Backup de inicializacao: '+$backup)
Write-Host 'Pastas e credenciais preservadas. FrCaixaMonitor nao foi alterado. Nenhum registro foi excluido do Lovable.'
Write-Host 'Reexecute sem -Aplicar apos reiniciar o Windows para verificar se alguma politica externa recria o agente.'
