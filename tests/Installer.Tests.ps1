param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/Common.ps1')
function sc.exe { $script:observed=@($args);$global:LASTEXITCODE=0 }
Invoke-Sc -Arguments @('create','InfraMonitorAgent','binPath=','"C:\example path\Agent.exe" --service','start=','auto')
if ($script:observed.Count -ne 6 -or $script:observed[3] -ne '"C:\example path\Agent.exe" --service') { throw 'SCM argumentos não preservados.' }
Write-Host 'PASS SCM argumentos com espaços preservados (SCM substituído por double)'
Remove-Item Function:\sc.exe
$files=@(Get-ChildItem (Join-Path $Repository 'scripts') -Filter *.ps1)+@(Get-ChildItem (Join-Path $Repository 'tests') -Filter *.ps1)
foreach ($file in $files) {
    $errors=$null;$tokens=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors) { throw ($errors|Out-String) }
    if ($file.Name -eq 'Install.ps1') {
        $calls=$ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Sc'},$true)
        foreach ($call in $calls) { if ($call.Extent.Text -notmatch 'Invoke-Sc -Arguments') { throw 'Chamada SCM sem array explícito.' } }
    }
}
Write-Host "PASS PowerShell AST: $($files.Count) scripts"
$work=Join-Path ([IO.Path]::GetTempPath()) ('uffa-installer-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    $p=Join-Path $work 'state.json';Write-Json $p @{step=1};Write-Json $p @{step=2}
    if ((Read-Json $p).step -ne 2) { throw 'Persistência inválida.' }
    Write-Host 'PASS estado de instalação substituído atomicamente'
    [IO.File]::WriteAllText((Join-Path $work 'host.uuid'),'11111111-1111-4111-8111-111111111111')
    [IO.File]::WriteAllText((Join-Path $work 'host.token'),('a'*64))
    $id=Get-IdentityFromLegacy $work
    if ($id.host_id -ne '11111111-1111-4111-8111-111111111111' -or $id.token.Length -ne 64) { throw 'Importação incorreta.' }
    Write-Host 'PASS identidade antiga UUID/token importada sem novo cadastro'
    Remove-Item (Join-Path $work 'host.token')
    $failed=$false;try { Get-IdentityFromLegacy $work | Out-Null } catch { $failed=$true }
    if (!$failed) { throw 'Identidade incompleta foi aceita.' }
    Write-Host 'PASS identidade incompleta recusada'
} finally { Remove-Item $work -Recurse -Force }
. (Join-Path $Repository 'scripts/ReadOnlyConfig.ps1')
$cfg=@([pscustomobject]@{id='frcaixa';kind='service';service_name='FrCaixaMonitor';allowed_operations=@('restart')},[pscustomobject]@{id='sql';kind='service';service_name='SQL';allowed_operations=@('stop')})
$catalog=ConvertTo-MonitoringOnlyCatalog $cfg
if ($catalog.Count -ne 2 -or @($catalog|Where-Object { $_.id -eq 'frcaixa' -and $_.kind -eq 'process' -and $_.process_name -eq 'monitor.exe' }).Count -ne 1) { throw 'Catalogo readonly incorreto.' }
if (@($catalog|Where-Object { $_.allowed_operations.Count -gt 0 -or $_.allow_force }).Count -gt 0) { throw 'Permissao de controle sobreviveu.' }
if ($cfg[0].allowed_operations[0] -ne 'restart') { throw 'Transformacao alterou objeto original.' }
$twice=ConvertTo-MonitoringOnlyCatalog $catalog
if ($twice.Count -ne 2) { throw 'Observador duplicado.' }
Write-Host 'PASS transformacao somente-monitoramento preserva outros alvos, remove operacoes e e repetivel'
Write-Host '6 verificações de scripts concluídas; instalação Windows não executada.'
