#requires -Version 5.1
[CmdletBinding()]
param([string]$Root='C:\infra-monitor-unificado')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Test-CatalogMigration([string]$Version) { return ([version]$Version -lt [version]'2.1.0') }
function Get-WebUpdateDecision([string]$Current,[string]$Desired,[bool]$HasService,[bool]$HasIdentity) {
    if (!$HasService -or !$HasIdentity) { throw 'Agente instalado e identidade existente obrigatorios. Use o instalador para instalacao nova.' }
    $a=$null;$b=$null
    if (![version]::TryParse($Current,[ref]$a) -or ![version]::TryParse($Desired,[ref]$b)) { throw 'Versao invalida; nenhuma alteracao realizada.' }
    if ($a -ge $b) { return 'Current' }
    return 'Update'
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

# Never install an immediate-renewal client against an empty-response polling backend.
function Test-LongPollResponse($Response,[double]$Seconds) {
    if (!$Response -or !$Response.PSObject.Properties['schema_version'] -or $Response.schema_version -ne 2 -or
        !$Response.PSObject.Properties['pending_commands']) { throw 'Contrato v2 de long-poll invalido; agente preservado.' }
    if (@($Response.pending_commands).Count -gt 0) { return 'Busy' }
    if ($Seconds -lt 20) { throw 'Servidor ainda responde imediatamente com fila vazia. Publique o suporte a wait=25 no backend antes de atualizar as lojas. Agente preservado.' }
    return 'Ready'
}
function Assert-LongPollingBackend([string]$Directory) {
    $config=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Directory 'config/agent.json')))
    $identity=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Directory 'config/identity.json')))
    $base=[string]$config.api_base_url;$uri=$null
    if (![Uri]::TryCreate($base,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'API HTTPS invalida; agente preservado.' }
    $headers=@{'X-Host-Id'=[string]$identity.host_id;'X-Host-Token'=[string]$identity.token;Accept='application/json'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    for ($attempt=0;$attempt -lt 3;$attempt++) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { $response=Invoke-RestMethod -UseBasicParsing -Uri ($base.TrimEnd('/')+'/agent-pull-config?wait=25') -Method Get -Headers $headers -TimeoutSec 35 -MaximumRedirection 0 }
        catch { throw 'Nao foi possivel confirmar long-poll autenticado no servidor. Confira API/rede/identidade; agente preservado.' }
        $watch.Stop()
        if ((Test-LongPollResponse $response $watch.Elapsed.TotalSeconds) -eq 'Ready') { return }
        # Commands are not acknowledged here: the running agent continues consuming its queue.
        Start-Sleep -Seconds 2
    }
    throw 'Fila com comandos pendentes; nao foi possivel confirmar a espera vazia. Aguarde o agente concluir os comandos e execute novamente. Agente preservado.'
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($env:OS -ne 'Windows_NT') { throw 'Execute em Windows PowerShell como administrador.' }
$who=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($who)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra PowerShell como administrador.' }
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($Root -notmatch '^[A-Za-z]:\\[^"\r\n]+$') { throw 'Raiz local invalida.' }
$exe=Join-Path $Root 'bin/InfraMonitor.Agent.exe'
$service=Get-CimInstance Win32_Service -Filter "Name='InfraMonitorAgent'"
$hasIdentity=Test-Path (Join-Path $Root 'config/identity.json')
if (!(Test-Path -LiteralPath $exe)) { throw 'Executavel do agente nao encontrado. Nao reinstale nem gere tokens por tentativa.' }
$version=& $exe --version
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel identificar a versao do agente existente.' }
$plan=Get-WebUpdateDecision $version '2.2.2' ($null -ne $service) $hasIdentity
if ($plan -eq 'Current') { Write-Host ('Agente ja esta na versao '+$version+' ou superior. Nenhum arquivo, token ou catalogo foi alterado.');return }
$work=Join-Path $env:ProgramData ('InfraMonitor-UpdateWeb-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    & icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Staging nao protegido. Atualizacao cancelada.' }
    Write-Host ('Atualizando '+$version+' para 2.2.2. UUID/token e diario serao preservados.')
    Assert-LongPollingBackend $Root
    Write-Host 'Servidor confirmou espera longa. Instalando agente com long-polling.'
    $url='https://raw.githubusercontent.com/fromNexz/UFFA/codex/agent-command-long-poll/dist/InfraMonitor-2.2.2.zip';$sha='036696c178725b0abbc3d0cc69b41fbe6ac9817e5e47a55687d49bfc7b27c4b4'
    $zip=Join-Path $work 'package.zip';Get-VerifiedArtifact $url $sha $zip
    $stage=Join-Path $work 'package';Expand-SafePackage $zip $stage
    . (Join-Path $stage 'scripts/Common.ps1')
    Assert-Admin
    $manifest=Assert-Package $stage
    if ($manifest.version -ne '2.2.2') { throw 'Versao inesperada do pacote.' }
    & (Join-Path $stage 'scripts/Update.ps1') -Root $Root -PackageUrl $url -PackageSha256 $sha -EnableRemoteMaintenance:(Test-CatalogMigration $version)
    Write-Host 'Atualizacao concluida e heartbeat confirmado. Confira catalogo no painel antes de solicitar acoes.'
} finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
