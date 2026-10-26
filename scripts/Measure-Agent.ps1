#requires -Version 5.1
[CmdletBinding()]
param([int]$Minutes=65,[string]$Output='C:\infra-monitor-unificado\logs\memory-measurement.csv')
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Admin
if ($Minutes -lt 1 -or $Minutes -gt 1440) { throw 'Duração inválida.' }
$rows=New-Object 'Collections.Generic.List[object]'
$end=[DateTime]::UtcNow.AddMinutes($Minutes)
while ([DateTime]::UtcNow -lt $end) {
    $svc=Get-CimInstance Win32_Service -Filter "Name='InfraMonitorAgent'"
    $processes=@(Get-Process -Name 'InfraMonitor.Agent' -ErrorAction SilentlyContinue)
    if ($svc -and $svc.ProcessId) { $wrapper=Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue;if ($wrapper -and $wrapper.ProcessName -ne 'InfraMonitor.Agent') { $processes+= $wrapper } }
    $rows.Add([pscustomobject]@{at=[DateTime]::UtcNow.ToString('o');pids=($processes.Id -join ',');working_set_mb=[Math]::Round((($processes|Measure-Object WorkingSet64 -Sum).Sum/1MB),2);private_mb=[Math]::Round((($processes|Measure-Object PrivateMemorySize64 -Sum).Sum/1MB),2);service_running=($null -ne $svc -and $svc.State -eq 'Running')})
    Start-Sleep -Seconds 1
}
$rows|Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $Output
$max=($rows|Measure-Object working_set_mb -Maximum).Maximum
$maxPrivate=($rows|Measure-Object private_mb -Maximum).Maximum
$missing=@($rows|Where-Object { !$_.service_running }).Count
Write-Host "Pico working set: $max MB; private: $maxPrivate MB; serviço ausente: $missing amostras. CSV: $Output"
if ($max -ge 100 -or $maxPrivate -ge 100 -or $missing -gt 0) { throw 'Critério obrigatório falhou (<100 MB e serviço continuamente disponível).' }
if ($max -ge 50 -or $maxPrivate -ge 50) { Write-Warning 'Teto obrigatório atendido, mas meta preferencial de <50 MB não atingida.' }
