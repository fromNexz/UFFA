param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$path=Join-Path $Repository 'maintenance/Atualizar-InfraMonitor-Web.ps1'
$e=$null;$t=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);if ($e) { throw ($e|Out-String) }
. $path
$count=0
function Check([string]$Name,[bool]$Ok){if(!$Ok){throw "FAIL $Name"};$script:count++;Write-Host "PASS $Name"}
function Refused([scriptblock]$Body){try{&$Body|Out-Null;return $false}catch{return $true}}
Check 'Atualiza 2.0.0 sem recadastro' ((Get-WebUpdateDecision '2.0.0' '2.1.0' $true $true) -eq 'Update')
Check 'Atualiza 2.0.1 sem recadastro' ((Get-WebUpdateDecision '2.0.1' '2.1.0' $true $true) -eq 'Update')
Check 'Repeticao na mesma versao nao altera configuracao' ((Get-WebUpdateDecision '2.1.0' '2.1.0' $true $true) -eq 'Current')
Check 'Nao faz downgrade' ((Get-WebUpdateDecision '3.0.0' '2.1.0' $true $true) -eq 'Current')
Check 'Sem identidade nao registra automaticamente' (Refused { Get-WebUpdateDecision '2.0.0' '2.1.0' $true $false })
Check 'Sem servico nao confunde instalacao com update' (Refused { Get-WebUpdateDecision '2.0.0' '2.1.0' $false $true })
Check 'Versao invalida nao prossegue' (Refused { Get-WebUpdateDecision 'broken' '2.1.0' $true $true })
Write-Host "$count testes do atualizador web passaram; nenhum servico Windows foi alterado."
