#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$LegacyRoot)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Admin
$i=Get-IdentityFromLegacy $LegacyRoot
$sha=[Security.Cryptography.SHA256]::Create()
try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($i.token))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
# Safe import metadata only. Raw token is never printed or sent to the browser.
@{host_id=$i.host_id;existing_token_sha256=$hash}|ConvertTo-Json
