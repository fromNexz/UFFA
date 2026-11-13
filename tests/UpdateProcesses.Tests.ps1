param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/UpdateProcesses.ps1')
$originalRequest=(Get-Command Request-UpdateAgentStop).ScriptBlock
Add-Type -TypeDefinition @'
using System;
public sealed class UffaUpdateFakeService:IDisposable {
 public string Status="Running";public UffaUpdateFakeService[] DependentServices=new UffaUpdateFakeService[0];public int StopCalls;
 public void Refresh(){} public void Stop(){StopCalls++;Status="Stopped";} public void Dispose(){}
}
public sealed class UffaUpdateFakeProcess:IDisposable {
 public IntPtr Handle=new IntPtr(1);public DateTime StartTime;public bool HasExited,Disposed;public int Kills;
 public void Kill(){Kills++;HasExited=true;} public bool WaitForExit(int milliseconds){return HasExited;} public void Dispose(){Disposed=true;}
}
'@
$work=Join-Path ([IO.Path]::GetTempPath()) ('uffa-update-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $work 'bin'))
$exe=Join-Path $work 'bin/InfraMonitor.Agent.exe'
[IO.File]::WriteAllText($exe,'test fixture')
$script:mode='Normal';$script:stopRequested=0;$count=0
function Check([string]$Name,[bool]$Ok){if(!$Ok){throw "FAIL $Name"};$script:count++;Write-Host "PASS $Name"}
function Refused([scriptblock]$Body){try{& $Body|Out-Null;return $false}catch{return $true}}
function Reset-Live {
 $script:mode='Normal';$script:stopRequested=0
 $script:fake=[UffaUpdateFakeProcess]::new();$script:fake.StartTime=[datetime]::UtcNow
 $script:observed=[pscustomobject]@{ProcessId=4242;ExecutablePath=$exe;CreationDate=$script:fake.StartTime}
}
# Windows process/SCM calls are replaced; real file-sharing checks use temporary fixture files.
function Get-Service {param($Name,$ErrorAction) return $script:fakeService }
function Get-Process {param($Id,$ErrorAction) return $script:fake }
function Get-CimInstance {
 param($ClassName,$Filter,$ErrorAction)
 if ($script:fake.HasExited -and $script:mode -ne 'Respawn') { return }
 if ($Filter -like 'ProcessId=*' -and $script:mode -eq 'Reused') { return [pscustomobject]@{ProcessId=4242;ExecutablePath=$exe;CreationDate=$script:observed.CreationDate.AddMinutes(1)} }
 return $script:observed
}
function Request-UpdateAgentStop { $script:stopRequested++;if($script:mode -eq 'Graceful'){$script:fake.HasExited=$true} }
function Test-UpdateAgentStopped { return $script:fake.HasExited }
try {
 $script:fakeService=[UffaUpdateFakeService]::new()
 & $originalRequest
 Check 'Service without dependents receives normal stop' ($script:fakeService.StopCalls -eq 1)
 $script:fakeService=[UffaUpdateFakeService]::new();$script:fakeService.DependentServices=@([UffaUpdateFakeService]::new())
 Check 'Active dependent prevents cascading service stops' ((Refused {& $originalRequest}) -and $script:fakeService.StopCalls -eq 0)
 Reset-Live
 Check 'Exact installation executable accepted' (Test-UpdateProcessPath $work $script:observed)
 Check 'Same name in another installation preserved' (!(Test-UpdateProcessPath $work ([pscustomobject]@{ExecutablePath=(Join-Path $work 'other/bin/InfraMonitor.Agent.exe')})))
 Check 'FrCaixaMonitor and inaccessible paths preserved' (!(Test-UpdateProcessPath $work ([pscustomobject]@{ExecutablePath='C:\FrCaixaMonitor\monitor.exe'})) -and !(Test-UpdateProcessPath $work ([pscustomobject]@{ExecutablePath=$null})))
 Reset-Live;$script:mode='Reused'
 Check 'Recycled PID not killed' ((Refused {Stop-UpdateAgentProcess $work $script:observed}) -and $script:fake.Kills -eq 0 -and $script:fake.Disposed)
 Reset-Live;$script:fake.StartTime=$script:fake.StartTime.AddMinutes(1)
 Check 'Pinned handle start time mismatch refused' ((Refused {Stop-UpdateAgentProcess $work $script:observed}) -and $script:fake.Kills -eq 0)
 Reset-Live;$script:fake.HasExited=$true
 Stop-UpdateAgentProcess $work $script:observed
 Check 'Exited process needs no kill' ($script:fake.Kills -eq 0)
 Reset-Live;$script:mode='Graceful'
 Stop-AgentForUpdate $work -GraceSeconds 0 -ReleaseSeconds 1
 Check 'Graceful service exit avoids force' ($script:stopRequested -eq 1 -and $script:fake.Kills -eq 0)
 Reset-Live
 Stop-AgentForUpdate $work -GraceSeconds 0 -ReleaseSeconds 1
 Check 'Persistent scoped process killed and awaited before update' ($script:stopRequested -eq 1 -and $script:fake.Kills -eq 1 -and $script:fake.HasExited -and $script:fake.Disposed)
 Reset-Live;$script:mode='Respawn'
 Check 'External respawn aborts instead of repeatedly killing' ((Refused {Stop-AgentForUpdate $work -GraceSeconds 0 -ReleaseSeconds 1}) -and $script:fake.Kills -eq 1)
 $lock=[IO.File]::Open($exe,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try { Check 'Locked binary prevents copying' (!(Test-UpdateBinariesUnlocked $work)) } finally { $lock.Dispose() }
 Check 'Released binary permits copying' (Test-UpdateBinariesUnlocked $work)
 Reset-Live
 Check 'Invalid wait rejected before service mutation' ((Refused {Stop-AgentForUpdate $work -GraceSeconds 0 -ReleaseSeconds 0}) -and $script:stopRequested -eq 0)
 Write-Host "$count testes de parada para atualizacao passaram; SCM e processos Windows simulados."
} finally { Remove-Item -LiteralPath $work -Recurse -Force }
