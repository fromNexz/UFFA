#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$AgentExe)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Esta suite precisa de Windows real; nao valida coletores por simulacao.' }
# Production assembly is x86 / .NET Framework, even on Windows x64.
if ([Environment]::Is64BitProcess) {
    & "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $PSCommandPath -AgentExe $AgentExe
    exit $LASTEXITCODE
}
[void][Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AgentExe).Path)
$work=Join-Path $env:TEMP ('uffa-script-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$count=0
function Check([string]$Name,[bool]$Ok) { if (!$Ok) { throw "FAIL $Name" };$script:count++;Write-Host "PASS $Name" }
function Run([string]$Target,[string]$Script,[int]$Timeout=10,[string]$WorkingDirectory=$work) {
    $command=New-Object 'Collections.Generic.Dictionary[string,object]'
    $command['target_id']=$Target;$command['operation']='start'
    $command['reason']=@{script=$Script;timeout=$Timeout;working_dir=$WorkingDirectory}|ConvertTo-Json -Compress
    $request=[Uffa.InfraMonitor.ScriptRequest]::Parse($command)
    return [Uffa.InfraMonitor.NativeScriptRunner]::Run($request,[Func[bool]]{ return $false })
}
try {
    $r=Run 'powershell' 'Write-Output "ação e aspas"; [Console]::Error.Write("stderr")'
    Check 'PowerShell quotes Unicode stdout and stderr' ($r.Code -eq 0 -and $r.Output.Contains('ação e aspas') -and $r.Output.Contains('stderr'))
    $r=Run 'cmd' 'echo "a & b"'
    Check 'CMD internal quotes and ampersand' ($r.Code -eq 0 -and $r.Output.Contains('a & b'))
    $r=Run 'powershell' 'Write-Output "falha"; exit 7'
    Check 'Explicit nonzero exit' ($r.Code -eq 7 -and $r.Output.Contains('falha'))
    $r=Run 'powershell' '[Console]::Out.Write(("x" * 200000)); [Console]::Error.Write(("y" * 200000))'
    Check 'Large dual stream output bounded and does not deadlock' ($r.Code -eq 0 -and $r.Output.Length -le 1814 -and $r.Output.EndsWith('[... truncado]'))
    $r=Run 'powershell' '(Get-Location).Path'
    Check 'Working directory honored' ($r.Code -eq 0 -and $r.Output.Trim() -eq $work)
    $missing=$false;try { Run 'cmd' 'echo test' 10 (Join-Path $work 'missing')|Out-Null } catch { $missing=$true }
    Check 'Invalid directory fails before process launch' $missing
    $pidFile=Join-Path $work 'child.pid';$escaped=$pidFile.Replace("'","''")
    $code='$p=Start-Process powershell.exe -ArgumentList ''-NoProfile -NonInteractive -Command Start-Sleep -Seconds 30'' -PassThru; [IO.File]::WriteAllText('''+$escaped+''',[string]$p.Id); Start-Sleep -Seconds 30'
    $r=Run 'powershell' $code 5
    Check 'Timeout reported' $r.TimedOut
    if (!(Test-Path -LiteralPath $pidFile)) { throw 'Child did not start in time; tree termination test inconclusive.' }
    $childId=[int][IO.File]::ReadAllText($pidFile)
    Check 'Timeout terminates descendant as well as root' ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue))
    Write-Host "$count verificacoes reais Windows passaram."
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
