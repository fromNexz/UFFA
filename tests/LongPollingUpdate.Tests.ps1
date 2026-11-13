param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$path=Join-Path $Repository 'maintenance/Atualizar-LongPolling.ps1'
$e=$null;$t=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
if ($e) { throw ($e|Out-String) }
. $path
function Check([string]$Name,[bool]$Ok){if(!$Ok){throw "FAIL $Name"};Write-Host "PASS $Name"}
function Refused([scriptblock]$Body){try{&$Body|Out-Null;return $false}catch{return $true}}
$empty=[pscustomobject]@{schema_version=2;pending_commands=@()}
$busy=[pscustomobject]@{schema_version=2;pending_commands=@([pscustomobject]@{id='pending'})}
Check 'Empty immediate backend cannot install hot-loop client' (Refused { Test-LongPollResponse $empty 0.2 })
Check 'Authenticated idle wait allows update' ((Test-LongPollResponse $empty 24.8) -eq 'Ready')
Check 'Pending commands do not prove wait support' ((Test-LongPollResponse $busy 0.1) -eq 'Busy')
Check 'Invalid schema rejected' (Refused { Test-LongPollResponse ([pscustomobject]@{schema_version=1;pending_commands=@()}) 25 })
Check 'Missing command queue rejected' (Refused { Test-LongPollResponse ([pscustomobject]@{schema_version=2}) 25 })
Check 'Installed version is idempotent' ((Get-WebUpdateDecision '2.2.2' '2.2.2' $true $true) -eq 'Current')
Check 'Existing 2.2.1 agents upgrade' ((Get-WebUpdateDecision '2.2.1' '2.2.2' $true $true) -eq 'Update')
Check 'Missing identity cannot enroll a new host' (Refused { Get-WebUpdateDecision '2.2.1' '2.2.2' $true $false })
Write-Host '8 testes passaram. Nenhum servico Windows foi alterado.'
