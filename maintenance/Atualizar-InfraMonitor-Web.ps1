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
$plan=Get-WebUpdateDecision $version '2.1.1' ($null -ne $service) $hasIdentity
if ($plan -eq 'Current') { Write-Host ('Agente ja esta na versao '+$version+' ou superior. Nenhum arquivo, token ou catalogo foi alterado.');return }
$work=Join-Path $env:ProgramData ('InfraMonitor-UpdateWeb-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    & icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Staging nao protegido. Atualizacao cancelada.' }
    Write-Host ('Atualizando '+$version+' para 2.1.1. UUID/token e diario serao preservados.')
    Write-Host 'O novo catalogo autoriza acoes administrativas FrCaixa, RustDesk e limpeza; nenhuma acao e executada durante a atualizacao.'
    $url='https://raw.githubusercontent.com/fromNexz/UFFA/v2.1.1/dist/InfraMonitor-2.1.1.zip';$sha='52e0c72085c4537a8bb6fa6537f0db363640cb6bca079a0de73bf06a76f4f213'
    $zip=Join-Path $work 'package.zip';Get-VerifiedArtifact $url $sha $zip
    $stage=Join-Path $work 'package';Expand-SafePackage $zip $stage
    . (Join-Path $stage 'scripts/Common.ps1')
    Assert-Admin
    $manifest=Assert-Package $stage
    if ($manifest.version -ne '2.1.1') { throw 'Versao inesperada do pacote.' }
    & (Join-Path $stage 'scripts/Update.ps1') -Root $Root -PackageUrl $url -PackageSha256 $sha -EnableRemoteMaintenance:(Test-CatalogMigration $version)
    Write-Host 'Atualizacao concluida e heartbeat confirmado. Confira catalogo no painel antes de solicitar acoes.'
} finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
