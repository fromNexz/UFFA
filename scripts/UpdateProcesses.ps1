#requires -Version 5.1
# Loaded before replacing scripts; functions remain available during rollback.
function Test-UpdateProcessPath([string]$Root,$Process) {
    $observed=[string]$Process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($observed)) { return $false }
    foreach ($name in @('InfraMonitor.Agent.exe','InfraMonitor.UserTask.exe')) {
        $expected=[IO.Path]::GetFullPath((Join-Path $Root "bin/$name"))
        if ([string]::Equals($observed,$expected,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-UpdateAgentProcesses([string]$Root) {
    Get-CimInstance Win32_Process -Filter "Name='InfraMonitor.Agent.exe' OR Name='InfraMonitor.UserTask.exe'" -ErrorAction Stop |
        Where-Object { Test-UpdateProcessPath $Root $_ }
}
function Stop-UpdateAgentProcess([string]$Root,$Observed) {
    if (!(Test-UpdateProcessPath $Root $Observed)) { throw 'Processo fora dos executaveis da instalacao; encerramento recusado.' }
    $processId=[int]$Observed.ProcessId
    if ($processId -le 0 -or !$Observed.CreationDate) { throw 'Identidade do processo incompleta; encerramento recusado.' }
    $live=Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (!$live) { return }
    try {
        # Pin the process handle before checking WMI again, then kill through this object, never by recycled PID.
        if ($live.HasExited) { return }
        [void]$live.Handle
        $current=@(Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop)
        if ($current.Count -eq 0) { return }
        if ($current.Count -ne 1 -or !(Test-UpdateProcessPath $Root $current[0]) -or !$current[0].CreationDate -or
            ([datetime]$current[0].CreationDate).ToUniversalTime().Ticks -ne ([datetime]$Observed.CreationDate).ToUniversalTime().Ticks -or
            [Math]::Abs(($live.StartTime.ToUniversalTime()-([datetime]$current[0].CreationDate).ToUniversalTime()).TotalSeconds) -gt 1) {
            throw 'PID/caminho/horario mudou; processo preservado e atualizacao interrompida.'
        }
        try { if (!$live.HasExited) { $live.Kill() } } catch [InvalidOperationException] { if (!$live.HasExited) { throw } }
        if (!$live.WaitForExit(5000)) { throw "Processo PID $processId nao confirmou encerramento em 5s." }
        Write-Host "Processo da instalacao encerrado: PID $processId."
    } catch [InvalidOperationException] { if (!$live.HasExited) { throw } } finally { $live.Dispose() }
}
function Request-UpdateAgentStop {
    $svc=Get-Service InfraMonitorAgent -ErrorAction Stop
    try {
        $svc.Refresh()
        if ($svc.Status -notin @('Stopped','StopPending')) {
            $dependents=@($svc.DependentServices);$activeDependent=$false
            try { foreach ($dependent in $dependents) { $dependent.Refresh();if ($dependent.Status -ne 'Stopped') { $activeDependent=$true } } }
            finally { foreach ($dependent in $dependents) { $dependent.Dispose() } }
            if ($activeDependent) { throw 'Servico possui dependentes ativos; parada recusada para preservar os outros servicos.' }
            try { $svc.Stop() } catch { Write-Warning 'Parada normal do servico nao aceita; verificando os processos da instalacao.' }
        }
    } finally { $svc.Dispose() }
}
function Test-UpdateAgentStopped {
    $svc=Get-Service InfraMonitorAgent -ErrorAction Stop
    try { $svc.Refresh();return $svc.Status -eq 'Stopped' } finally { $svc.Dispose() }
}
function Test-UpdateBinariesUnlocked([string]$Root) {
    foreach ($name in @('InfraMonitor.Agent.exe','InfraMonitor.UserTask.exe')) {
        $file=Join-Path $Root "bin/$name"
        if (!(Test-Path -LiteralPath $file)) { continue }
        try { $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$stream.Dispose() }
        catch [IO.IOException] { return $false }
    }
    return $true
}
function Stop-AgentForUpdate([string]$Root,[int]$GraceSeconds=15,[int]$ReleaseSeconds=15) {
    if ($GraceSeconds -lt 0 -or $GraceSeconds -gt 60 -or $ReleaseSeconds -lt 1 -or $ReleaseSeconds -gt 60) { throw 'Prazo de parada invalido.' }
    Request-UpdateAgentStop
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining=@(Get-UpdateAgentProcesses $Root)
        if ($remaining.Count -eq 0 -and (Test-UpdateAgentStopped) -and (Test-UpdateBinariesUnlocked $Root)) { return }
        if ($clock.Elapsed.TotalSeconds -ge $GraceSeconds) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    foreach ($process in @(Get-UpdateAgentProcesses $Root)) { Stop-UpdateAgentProcess $Root $process }
    $clock.Restart()
    do {
        if (@(Get-UpdateAgentProcesses $Root).Count -eq 0 -and (Test-UpdateAgentStopped) -and (Test-UpdateBinariesUnlocked $Root)) { return }
        Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt $ReleaseSeconds)
    throw 'Agente/servico continua ativo ou executavel bloqueado. Arquivos nao foram substituidos; verifique reinicio externo ou antivirus.'
}
