param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$source=@('agent/src/Core.cs','agent/src/Program.cs','tests/Agent.Tests.cs')|ForEach-Object { Join-Path $Repository $_ }
if ($PSVersionTable.PSEdition -eq 'Core') {
    $refs=@(Get-ChildItem (Join-Path $PSHOME 'ref/*.dll')|ForEach-Object FullName)
    Add-Type -Path $source -ReferencedAssemblies $refs -CompilerOptions @('/define:PORTABLE_TEST','/nowarn:SYSLIB0014') -ErrorAction Stop
} else { Add-Type -Path $source -ReferencedAssemblies System.Web.Extensions,System.Core }
$work=Join-Path ([IO.Path]::GetTempPath()) ('uffa-tests-'+[Guid]::NewGuid().ToString('N'))
try { $results=[AgentTests]::Run($work);foreach ($r in $results) { Write-Host "PASS $r" };Write-Host "$($results.Length) testes passaram; chamadas Windows substituídas por doubles que lançam erro." }
finally { if (Test-Path $work) { Remove-Item $work -Recurse -Force } }
