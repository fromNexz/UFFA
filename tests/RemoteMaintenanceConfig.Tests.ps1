param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/RemoteMaintenanceConfig.ps1')
$count=0
function Check([string]$Name,[bool]$Ok){if(!$Ok){throw "FAIL $Name"};$script:count++;Write-Host "PASS $Name"}
$old=@([pscustomobject]@{id='frcaixa';kind='service';executable='D:\ERP\monitor.exe';health_tcp_port=4242;allowed_operations=@()},[pscustomobject]@{id='database';kind='service';service_name='SQL';allowed_operations=@('stop')})
$catalog=ConvertTo-RemoteMaintenanceCatalog $old 'D:\ERP\monitor.exe'
Check 'Identidade/entrada antiga nao alterada' ($old[0].kind -eq 'service' -and $old[0].allowed_operations.Count -eq 0)
Check 'Tres alvos obrigatorios sem duplicatas' (@($catalog|Where-Object { $_.id -in @('frcaixa','rustdesk','system_cleanup') }).Count -eq 3)
$fr=@($catalog|Where-Object id -eq 'frcaixa')[0];$rust=@($catalog|Where-Object id -eq 'rustdesk')[0];$clean=@($catalog|Where-Object id -eq 'system_cleanup')[0]
Check 'Sonda funcional local preservada' ($fr.health_tcp_port -eq 4242)
Check 'Caminho local FrCaixa preservado' ($fr.executable -eq 'D:\ERP\monitor.exe' -and $fr.remote_control_enabled -and $fr.allowed_operations.Count -eq 4 -and $fr.allow_force)
Check 'RustDesk caminho fixo e operacoes declaradas' ($rust.executable -eq 'C:\Program Files\RustDesk\RustDesk.exe' -and $rust.allowed_operations.Count -eq 4 -and $rust.allow_force)
Check 'Limpeza apenas start sem force' ($clean.allowed_operations.Count -eq 1 -and $clean.allowed_operations[0] -eq 'start' -and !$clean.allow_force)
Check 'Outros alvos preservados somente para leitura' (@($catalog|Where-Object { $_.id -eq 'database' -and $_.allowed_operations.Count -eq 0 }).Count -eq 1)
$again=ConvertTo-RemoteMaintenanceCatalog $catalog 'D:\ERP\monitor.exe'
Check 'Transformacao repetivel nao duplica alvos' ($again.Count -eq $catalog.Count)
Check 'Descoberta prefere caminho local ja configurado' ((Get-FrCaixaExecutable $old) -eq 'D:\ERP\monitor.exe')
$failed=$false;try {ConvertTo-RemoteMaintenanceCatalog $old '\\server\app.exe'|Out-Null}catch{$failed=$true};Check 'Caminho UNC recusado' $failed
$failed=$false;try {ConvertTo-RemoteMaintenanceCatalog $old 'C:\ERP\..\cmd.exe'|Out-Null}catch{$failed=$true};Check 'Travessia recusada' $failed
Write-Host "$count verificacoes do catalogo remoto passaram. Nenhuma acao Windows executada."
