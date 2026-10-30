#requires -Version 5.1
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ApiBaseUrl,
 [ValidateSet('New','Migrate')][string]$Mode='New',
 [string]$Root='C:\infra-monitor-unificado',
 [Security.SecureString]$EnrollmentCode,
 [string]$LegacyRoot,
 [string]$LegacyServiceName,
 [ValidateSet('Native','Nssm')][string]$ServiceWrapper='Native',
 [string]$NssmPath,[string]$NssmUrl,[string]$NssmSha256,
 [switch]$Resume,
 [switch]$MonitoringOnly
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Admin
$api=[Uri]$ApiBaseUrl
if ($api.Scheme -ne 'https' -or $api.UserInfo -or $api.Query -or $api.Fragment) { throw 'Informe URL HTTPS sem credenciais, query ou fragmento.' }
$Root=[IO.Path]::GetFullPath($Root)
if ($Root -notmatch '^[A-Za-z]:\\[^"\r\n]+$' -or $Root.TrimEnd('\').Length -lt 5) { throw 'Raiz local inválida.' }
$package=Split-Path $PSScriptRoot -Parent
$manifest=Assert-Package $package
$existing=Get-CimInstance Win32_Service -Filter "Name='InfraMonitorAgent'"
$reuse=($null -ne $existing -and $Mode -eq 'Migrate' -and $LegacyServiceName -eq 'InfraMonitorAgent')
if ($existing -and !$reuse) { throw 'Serviço já instalado. Use Update.ps1, ou migração explícita com LegacyServiceName InfraMonitorAgent.' }
if ($reuse -and ($existing.StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM') -or $ServiceWrapper -ne 'Native')) { throw 'Migração com mesmo nome requer serviço LocalSystem e wrapper Native; conta personalizada exige migração assistida.' }
if (!$Resume -and (Test-Path $Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count) { throw 'Destino não vazio; preserve-o e use atualização ou escolha outra raiz.' }
$oldWasRunning=$false;$created=$false;$reconfigured=$false;$identity=$null
$oldStart=if ($reuse) { switch ($existing.StartMode) { 'Auto' {'auto'} 'Manual' {'demand'} 'Disabled' {'disabled'} default {throw 'Modo de serviço desconhecido.'} } } else {$null}
try {
    foreach ($dir in @('','bin','config','state','state/commands','state/outbox','logs','backups','tools')) { [void][IO.Directory]::CreateDirectory((Join-Path $Root $dir)) }
    Set-PrivateAcl $Root
    if (!(Test-Path (Join-Path $Root 'scripts'))) { Copy-Item -LiteralPath (Join-Path $package 'scripts') -Destination (Join-Path $Root 'scripts') -Recurse }
    Copy-Item -LiteralPath (Join-Path $package 'bin/InfraMonitor.Agent.exe') -Destination (Join-Path $Root 'bin/InfraMonitor.Agent.exe')
    $cfg=if ($Resume -and (Test-Path (Join-Path $Root 'config/agent.json'))) { Read-Json (Join-Path $Root 'config/agent.json') } else { Read-Json (Join-Path $package 'agent/config/agent.example.json') };$cfg.api_base_url=$ApiBaseUrl.TrimEnd('/')
    if ($MonitoringOnly) {
        . (Join-Path $PSScriptRoot 'ReadOnlyConfig.ps1')
        $configPath=Join-Path $Root 'config/agent.json'
        if (Test-Path $configPath) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $Root ('backups/config-before-monitoring-'+[Guid]::NewGuid().ToString('N')+'.json')) }
        $cfg.catalog=ConvertTo-MonitoringOnlyCatalog $cfg.catalog
    }
    Write-Json (Join-Path $Root 'config/agent.json') $cfg
    if ($Mode -eq 'Migrate') {
        if (!$LegacyRoot -or !$LegacyServiceName) { throw 'Migração exige LegacyRoot e LegacyServiceName explícitos.' }
        $legacyFull=[IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\')+'\'
        $targetFull=$Root.TrimEnd('\')+'\'
        if ($targetFull.StartsWith($legacyFull,[StringComparison]::OrdinalIgnoreCase) -or $legacyFull.StartsWith($targetFull,[StringComparison]::OrdinalIgnoreCase)) { throw 'Diretórios de origem e destino não podem se sobrepor.' }
        $identity=Get-IdentityFromLegacy $LegacyRoot
        $old=Get-Service -Name $LegacyServiceName -ErrorAction Stop
        $oldWasRunning=$old.Status -eq 'Running'
        # Backup complete original directory (including identity); source never removed.
        if (!(Test-Path (Join-Path $Root 'backups/legacy'))) { Copy-Item -LiteralPath $LegacyRoot -Destination (Join-Path $Root 'backups/legacy') -Recurse }
        if ($reuse) { Write-Json (Join-Path $Root 'backups/legacy-service.json') @{path=$existing.PathName;start=$oldStart;display_name=$existing.DisplayName} }
        Set-PrivateAcl $Root
        if ($oldWasRunning) { Stop-Service -Name $LegacyServiceName -ErrorAction Stop }
    } elseif ($Resume -and (Test-Path (Join-Path $Root 'config/identity.json'))) {
        $identity=Read-Json (Join-Path $Root 'config/identity.json')
    } elseif ($Resume -and (Test-Path (Join-Path $Root 'config/enrollment.pending.json'))) {
        & (Join-Path $PSScriptRoot 'Resume-Enrollment.ps1') -Root $Root -ApiBaseUrl $ApiBaseUrl
        $identity=Read-Json (Join-Path $Root 'config/identity.json')
    } else {
        if (!$EnrollmentCode) { $EnrollmentCode=Read-Host 'Código de cadastro de uso único emitido pelo painel' -AsSecureString }
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($EnrollmentCode)
        try { $code=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        $request=[Guid]::NewGuid().ToString()
        # Restricted durable recovery file permits retry after response loss. Delete after successful enrollment.
        Write-Json (Join-Path $Root 'config/enrollment.pending.json') @{code=$code;request_id=$request}
        & (Join-Path $PSScriptRoot 'Resume-Enrollment.ps1') -Root $Root -ApiBaseUrl $ApiBaseUrl
        $identity=Read-Json (Join-Path $Root 'config/identity.json');$code=$null
    }
    Write-Json (Join-Path $Root 'config/identity.json') $identity
    Set-PrivateAcl $Root
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try {
        $response=Invoke-RestMethod -Uri "$($ApiBaseUrl.TrimEnd('/'))/agent-pull-config" -Method Get -Headers @{'X-Host-Id'=$identity.host_id;'X-Host-Token'=$identity.token;Accept='application/json'} -TimeoutSec 20 -MaximumRedirection 0
        if ($response.schema_version -ne 2) { throw 'Contrato incompatível.' }
    } catch { throw 'Backend v2 não confirmou identidade. Confira importação/cadastro e URL; token preservado.' }
    $exe=Join-Path $Root 'bin/InfraMonitor.Agent.exe'
    if ($reuse) {
        Invoke-Sc -Arguments @('config','InfraMonitorAgent','binPath=',('"'+$exe+'" --service --root "'+$Root+'"'),'start=','auto')
        $reconfigured=$true
    } elseif ($ServiceWrapper -eq 'Native') {
        Invoke-Sc -Arguments @('create','InfraMonitorAgent','binPath=',('"'+$exe+'" --service --root "'+$Root+'"'),'start=','auto','obj=','LocalSystem','DisplayName=','UFFA Infra Monitor Agent')
        $created=$true
    } else {
        $nssm=Join-Path $Root 'tools/nssm.exe'
        if ($NssmSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'NSSM exige SHA256 fixado por canal confiável.' }
        if ($NssmPath) { Copy-Item -LiteralPath $NssmPath -Destination $nssm }
        else {
            $u=[Uri]$NssmUrl;if ($u.Scheme -ne 'https' -or $u.UserInfo) { throw 'NssmUrl deve ser HTTPS para nssm.exe; não ZIP.' }
            Invoke-WebRequest -UseBasicParsing -Uri $NssmUrl -OutFile $nssm -TimeoutSec 60 -MaximumRedirection 0
        }
        if ((Get-FileHash $nssm -Algorithm SHA256).Hash -ine $NssmSha256) { Remove-Item $nssm -Force;throw 'SHA256 do NSSM divergente.' }
        & $nssm install InfraMonitorAgent $exe '--root' ('"'+$Root+'"');if ($LASTEXITCODE -ne 0) { throw 'Falha ao instalar NSSM.' };$created=$true
        foreach ($setting in @(@('Start','SERVICE_AUTO_START'),@('AppDirectory',$Root),@('AppExit','Default','Restart'),@('AppRestartDelay','15000'),@('AppStopMethodSkip','0'))) {
            & $nssm set InfraMonitorAgent @setting | Out-Null;if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar NSSM.' }
        }
    }
    if (!$reuse) {
    Invoke-Sc -Arguments @('failure','InfraMonitorAgent','reset=','86400','actions=','restart/15000/restart/30000/restart/60000')
    Invoke-Sc -Arguments @('description','InfraMonitorAgent','Agente UFFA com catálogo local, identidade individual e coleta horária.')
    # Protect service DACL: System + local Administrators may control or reconfigure it.
    Invoke-Sc -Arguments @('sdset','InfraMonitorAgent','D:(A;;CCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)')
    }
    Start-Service InfraMonitorAgent
    Wait-AgentHealthy $Root $manifest.version
    if ($Mode -eq 'Migrate' -and !$reuse) { Set-Service -Name $LegacyServiceName -StartupType Disabled }
    Copy-Item (Join-Path $package 'manifest.json') (Join-Path $Root 'manifest.json')
    Write-Host "InfraMonitorAgent $($manifest.version) instalado; heartbeat confirmado. FrCaixaMonitor protegido: somente monitoramento."
} catch {
    if ($created) { Stop-Service InfraMonitorAgent -ErrorAction SilentlyContinue; & sc.exe delete InfraMonitorAgent | Out-Null }
    if ($reconfigured) { Stop-Service InfraMonitorAgent -ErrorAction SilentlyContinue;Invoke-Sc -Arguments @('config','InfraMonitorAgent','binPath=',$existing.PathName,'start=',$oldStart) }
    if ($oldWasRunning) { Start-Service -Name $LegacyServiceName -ErrorAction SilentlyContinue }
    Write-Warning 'Instalação não concluída. Identidade e backup foram mantidos na raiz com ACL restrita. Não cadastre novamente; use o guia de recuperação.'
    throw
} finally { $EnrollmentCode=$null;$identity=$null }
