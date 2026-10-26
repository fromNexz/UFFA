#requires -Version 5.1
[CmdletBinding()]
param([string]$Root='C:\infra-monitor-unificado',[Parameter(Mandatory=$true)][string]$PackageUrl,[Parameter(Mandatory=$true)][string]$PackageSha256)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Artifacts.ps1')
Assert-Admin
$Root=[IO.Path]::GetFullPath($Root)
$service=Get-CimInstance Win32_Service -Filter "Name='InfraMonitorAgent'"
if (!$service -or $service.PathName.IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Serviço não corresponde à raiz indicada.' }
$stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$work=Join-Path $Root "state/update-$stamp";$backup=Join-Path $Root "backups/$stamp"
[void][IO.Directory]::CreateDirectory($work);[void][IO.Directory]::CreateDirectory($backup);Set-PrivateAcl $Root
$changed=$false
try {
    $zip=Join-Path $work 'release.zip';Get-VerifiedArtifact $PackageUrl $PackageSha256 $zip
    $stage=Join-Path $work 'package';Expand-SafePackage $zip $stage
    $manifest=Assert-Package $stage
    $current= & (Join-Path $Root 'bin/InfraMonitor.Agent.exe') --version
    if ([version]$manifest.version -le [version]$current) { throw 'Atualização exige versão superior à instalada. Rollback usa o backup.' }
    Copy-Item -LiteralPath (Join-Path $Root 'bin') -Destination (Join-Path $backup 'bin') -Recurse
    if (Test-Path (Join-Path $Root 'scripts')) { Copy-Item -LiteralPath (Join-Path $Root 'scripts') -Destination (Join-Path $backup 'scripts') -Recurse }
    Copy-Item -LiteralPath (Join-Path $Root 'config') -Destination (Join-Path $backup 'config') -Recurse
    if (Test-Path (Join-Path $Root 'manifest.json')) { Copy-Item (Join-Path $Root 'manifest.json') (Join-Path $backup 'manifest.json') }
    Set-PrivateAcl $Root
    Stop-Service InfraMonitorAgent -ErrorAction Stop
    $changed=$true
    Copy-Item -LiteralPath (Join-Path $stage 'bin/InfraMonitor.Agent.exe') -Destination (Join-Path $Root 'bin/InfraMonitor.Agent.exe') -Force
    if (Test-Path (Join-Path $Root 'scripts')) { Remove-Item (Join-Path $Root 'scripts') -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $stage 'scripts') -Destination (Join-Path $Root 'scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path $stage 'manifest.json') -Destination (Join-Path $Root 'manifest.json') -Force
    $health=Join-Path $Root 'state/health.json';if (Test-Path $health) { Remove-Item $health }
    Start-Service InfraMonitorAgent
    Wait-AgentHealthy $Root $manifest.version
    Write-Json (Join-Path $Root 'state/last-update.json') @{version=$manifest.version;backup=$backup;completed_at=[DateTime]::UtcNow.ToString('o')}
    Write-Host "Atualizado para $($manifest.version). Configuração, identidade e diário de comandos preservados. Backup: $backup"
} catch {
    if ($changed) {
        Stop-Service InfraMonitorAgent -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $backup 'bin/InfraMonitor.Agent.exe') -Destination (Join-Path $Root 'bin/InfraMonitor.Agent.exe') -Force
        if (Test-Path (Join-Path $backup 'manifest.json')) { Copy-Item (Join-Path $backup 'manifest.json') (Join-Path $Root 'manifest.json') -Force }
        if (Test-Path (Join-Path $backup 'scripts')) { if (Test-Path (Join-Path $Root 'scripts')) { Remove-Item (Join-Path $Root 'scripts') -Recurse -Force };Copy-Item (Join-Path $backup 'scripts') (Join-Path $Root 'scripts') -Recurse }
        Start-Service InfraMonitorAgent
        Wait-AgentHealthy $Root $current
        Write-Warning 'Rollback executado e heartbeat da versão anterior confirmado.'
    }
    throw
} finally { if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
