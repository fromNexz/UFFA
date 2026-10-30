param([string]$Repository=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$path=Join-Path $Repository 'maintenance/Instalar-InfraMonitor-Web.ps1'
$e=$null;$t=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);if ($e) { throw ($e|Out-String) }
. $path
$count=0
function Check([string]$Name,[bool]$Ok) { if (!$Ok) { throw "FAIL $Name" };$script:count++;Write-Host "PASS $Name" }
function Refused([scriptblock]$Run) { try { &$Run | Out-Null;return $false } catch { return $true } }
Check 'Nova instalacao em raiz vazia' ((Get-WebInstallPlan $false $false $true $false $false $false $false $false) -eq 'New')
Check 'Instalacao existente nao alterada' ((Get-WebInstallPlan $true $true $false $true $true $true $false $true) -eq 'Installed')
Check 'Servico antigo impede cadastro novo' (Refused { Get-WebInstallPlan $true $false $true $false $false $false $false $false })
Check 'Identidade parcial permite retomar' ((Get-WebInstallPlan $false $false $false $true $true $true $false $true) -eq 'Resume')
Check 'Enrollment pendente retoma mesmo request' ((Get-WebInstallPlan $false $false $false $true $true $false $true $true) -eq 'Resume')
Check 'Pasta desconhecida preservada' (Refused { Get-WebInstallPlan $false $false $false $false $true $true $false $true })
Check 'API diferente nao recebe identidade por tentativa' (Refused { Get-WebInstallPlan $false $false $false $true $false $true $false $true })
Check 'Identidade sem binario nao e raiz reconhecida' (Refused { Get-WebInstallPlan $false $false $false $true $true $true $false $false })
Check 'HTTP nao permitido' (Refused { Assert-WebApi 'http://example.com' })
Check 'Credenciais em URL nao permitidas' (Refused { Assert-WebApi 'https://user:secret@example.com' })
Check 'Query nao permitida' (Refused { Assert-WebApi 'https://example.com?token=x' })
Check 'URL HTTPS normalizada' ((Assert-WebApi 'https://example.com/api/') -eq 'https://example.com/api')
Write-Host "$count testes do iniciador passaram. Instalacao e servicos Windows nao executados."
