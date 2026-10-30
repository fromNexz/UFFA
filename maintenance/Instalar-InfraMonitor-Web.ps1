#requires -Version 5.1
[CmdletBinding()]
param([string]$ApiBaseUrl='https://infro-monitor.lovable.app/api/public/infra-monitor',[string]$Root='C:\infra-monitor-unificado')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Assert-WebApi([string]$Value) {
    $u=$null
    if (![Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$u) -or $u.Scheme -ne 'https' -or $u.UserInfo -or $u.Query -or $u.Fragment) { throw 'ApiBaseUrl exige HTTPS sem credenciais, query ou fragmento.' }
    return $Value.TrimEnd('/')
}
function Get-WebInstallPlan([bool]$ServiceExists,[bool]$OwnService,[bool]$RootEmpty,[bool]$KnownConfig,[bool]$SameApi,[bool]$HasIdentity,[bool]$HasPending,[bool]$HasBinary) {
    if ($ServiceExists) {
        if ($OwnService) { return 'Installed' }
        throw 'InfraMonitorAgent ja existe em outra instalacao. Execute a limpeza do agente antigo primeiro; nada foi alterado.'
    }
    if ($RootEmpty) { return 'New' }
    if ($KnownConfig -and $SameApi -and $HasBinary -and ($HasIdentity -or $HasPending)) { return 'Resume' }
    throw 'A pasta de destino nao esta vazia ou a API difere da instalacao parcial. Arquivos preservados; nao gere outro cadastro por tentativa.'
}
# HTTPS redirects are followed manually and never downgraded. Hash must come from a trusted release channel.
function Get-VerifiedArtifact([string]$Url,[string]$Sha256,[string]$OutFile) {
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'SHA256 obrigatório.' }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $current=$Url
    for ($redirect=0;$redirect -le 5;$redirect++) {
        $uri=[Uri]$current;if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Artefatos exigem HTTPS sem credenciais na URL.' }
        $req=[Net.HttpWebRequest]::Create($uri);$req.AllowAutoRedirect=$false;$req.Timeout=60000;$req.ReadWriteTimeout=60000
        $res=$req.GetResponse()
        try {
            $status=[int]$res.StatusCode
            if ($status -in @(301,302,303,307,308)) { $current=([Uri]::new($uri,$res.Headers['Location'])).AbsoluteUri;continue }
            if ($status -ne 200) { throw 'Falha no download de artefato.' }
            $input=$res.GetResponseStream();$output=[IO.File]::Create($OutFile)
            try {
                $buffer=New-Object byte[] 65536;$total=0
                while (($n=$input.Read($buffer,0,$buffer.Length)) -gt 0) { $total+=$n;if ($total -gt 52428800) { throw 'Artefato excede 50 MB.' };$output.Write($buffer,0,$n) }
            } finally { $input.Dispose();$output.Dispose() }
            if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ine $Sha256) { Remove-Item -LiteralPath $OutFile -Force;throw 'SHA256 divergente; artefato descartado.' }
            return
        } finally { $res.Dispose() }
    }
    throw 'Redirecionamentos em excesso.'
}
function Expand-SafePackage([string]$Zip,[string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory($Destination)
    $base=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $size=0;if ($archive.Entries.Count -gt 1000) { throw 'Pacote com arquivos em excesso.' }
        foreach ($entry in $archive.Entries) {
            $full=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            $size+=$entry.Length
            if (!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':') -or $size -gt 104857600) { throw 'Caminho ou tamanho de pacote inválido.' }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$Destination)
}

# Dot-sourcing exposes only pure helpers for tests; it never starts installation.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Requer Windows e PowerShell 5.1.' }
$who=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($who)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra PowerShell como administrador.' }
$ApiBaseUrl=Assert-WebApi $ApiBaseUrl
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($Root -notmatch '^[A-Za-z]:\\[^"\r\n]+$') { throw 'Raiz de instalacao local invalida.' }
$existing=Get-CimInstance Win32_Service -Filter "Name='InfraMonitorAgent'"
$own=$false
$exe=Join-Path $Root 'bin/InfraMonitor.Agent.exe'
if ($existing) { $own=[string]$existing.PathName -match ('(?i)^"?'+[regex]::Escape($exe)+'"?\s+--service(?:\s|$)') }
$empty=!(Test-Path -LiteralPath $Root) -or @(Get-ChildItem -LiteralPath $Root -Force).Count -eq 0
$configPath=Join-Path $Root 'config/agent.json';$known=$false;$same=$false
if (!$empty -and (Test-Path -LiteralPath $configPath)) {
    try {
        $cfg=ConvertFrom-Json ([IO.File]::ReadAllText($configPath))
        $known=$cfg.schema_version -eq 2
        $same=([string]$cfg.api_base_url).TrimEnd('/') -ceq $ApiBaseUrl
    } catch { $known=$false }
}
$plan=Get-WebInstallPlan -ServiceExists ($null -ne $existing) -OwnService $own -RootEmpty $empty -KnownConfig $known -SameApi $same -HasIdentity (Test-Path (Join-Path $Root 'config/identity.json')) -HasPending (Test-Path (Join-Path $Root 'config/enrollment.pending.json')) -HasBinary (Test-Path -LiteralPath $exe)
if ($plan -eq 'Installed') {
    Write-Host ('O agente novo ja esta instalado. Estado do servico: '+$existing.State+'. Nenhum cadastro, arquivo ou servico foi alterado.')
    Write-Host 'Para atualizar uma versao existente, use o procedimento de atualizacao; este iniciador nao reinstala automaticamente.'
    return
}
$stageRoot=Join-Path $env:ProgramData ('InfraMonitor-Web-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stageRoot)
try {
    & icacls.exe $stageRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel proteger o staging; instalacao cancelada.' }
    Write-Host 'Baixando e verificando o pacote 2.0.1...'
    $zip=Join-Path $stageRoot 'package.zip'
    Get-VerifiedArtifact 'https://raw.githubusercontent.com/fromNexz/UFFA/099644507abf320fb94169d5d717f878dd18e670/dist/InfraMonitor-2.0.1.zip' '38f80944615cd0ac64fe617480b72d3b6cd816f08716c8378e40a4961fb81133' $zip
    $package=Join-Path $stageRoot 'package'
    Expand-SafePackage $zip $package
    . (Join-Path $package 'scripts/Common.ps1')
    Assert-Admin
    $manifest=Assert-Package $package
    if ($manifest.version -ne '2.0.1') { throw 'Versao do pacote inesperada.' }
    . (Join-Path $package 'maintenance/legacy-cleanup/Remover-InfraMonitor-Antigo.ps1')
    $oldServices=@(Get-ServicosAntigos);$oldTasks=@(Get-TarefasAntigas);$oldProcesses=@(Get-ProcessosAntigos)
    if ($oldServices.Count+$oldTasks.Count+$oldProcesses.Count -gt 0) { throw 'Agente antigo ainda possui inicializacoes/processos. Execute a limpeza antiga primeiro. Nenhum arquivo da loja foi modificado.' }
    Write-Host ('Plano: '+$plan+'. FrCaixaMonitor sera apenas observado, nunca controlado.')
    if ($plan -eq 'Resume') { Write-Host 'Retomando a identidade/cadastro pendente existente. Nao e necessario outro codigo.' }
    & (Join-Path $package 'scripts/Install.ps1') -ApiBaseUrl $ApiBaseUrl -Root $Root -Mode New -Resume:($plan -eq 'Resume') -MonitoringOnly
    Write-Host 'Instalacao concluida. Confira a loja e as coletas no painel antes de repetir nas demais.'
} finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
