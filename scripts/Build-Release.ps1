#requires -Version 5.1
[CmdletBinding()]
param([string]$Repository=(Split-Path $PSScriptRoot -Parent),[string]$Output)
$ErrorActionPreference='Stop'
if (!$Output) { $Output=Join-Path $Repository 'dist' }
$csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
if (!(Test-Path $csc)) { throw 'Compilador .NET Framework não encontrado. Execute no Windows com .NET 4.7.2+.' }
$stage=Join-Path $Output ('package-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $stage 'bin'))
try {
    $exe=Join-Path $stage 'bin/InfraMonitor.Agent.exe'
    $sources=@(Get-ChildItem (Join-Path $Repository 'agent/src/*.cs')|ForEach-Object FullName)
    & $csc /nologo /optimize+ /target:exe /platform:x86 /r:System.Web.Extensions.dll /r:System.Management.dll /r:System.ServiceProcess.dll ("/out:$exe") @sources
    if ($LASTEXITCODE -ne 0) { throw 'Compilação falhou.' }
    $version= & $exe --version
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\.\d+$') { throw 'Executável não confirmou versão.' }
    Copy-Item (Join-Path $Repository 'scripts') (Join-Path $stage 'scripts') -Recurse
    [void][IO.Directory]::CreateDirectory((Join-Path $stage 'agent/config'))
    Copy-Item (Join-Path $Repository 'agent/config/agent.example.json') (Join-Path $stage 'agent/config/agent.example.json')
    Copy-Item (Join-Path $Repository 'docs') (Join-Path $stage 'docs') -Recurse
    Copy-Item (Join-Path $Repository 'README.md') (Join-Path $stage 'README.md')
    $files=@(Get-ChildItem $stage -File -Recurse|ForEach-Object { @{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
    @{version=$version;files=$files}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $stage 'manifest.json') -Encoding UTF8
    $zip=Join-Path $Output "InfraMonitor-$version.zip"
    if (Test-Path $zip) { throw 'Pacote já existe; incremente a versão antes de publicar outra release.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    $hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content "$zip.sha256" -Encoding ASCII
    Write-Host "Pacote criado: $zip; SHA256: $hash"
} finally { if (Test-Path $stage) { Remove-Item $stage -Recurse -Force } }
