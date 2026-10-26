#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$ApiBaseUrl)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Admin
$u=[Uri]$ApiBaseUrl;if ($u.Scheme -ne 'https' -or $u.UserInfo -or $u.Query -or $u.Fragment) { throw 'HTTPS obrigatório.' }
$pending=Join-Path $Root 'config/enrollment.pending.json'
if (!(Test-Path $pending)) { throw 'Não há cadastro pendente.' }
$p=Read-Json $pending
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
try {
    $identity=Invoke-RestMethod -Uri "$($ApiBaseUrl.TrimEnd('/'))/enroll" -Method Post -ContentType 'application/json' -Body (ConvertTo-Json @{code=$p.code;request_id=$p.request_id}) -TimeoutSec 20 -MaximumRedirection 0
} catch { throw 'Falha no cadastro. Arquivo pendente preservado para repetir o mesmo request_id; não gere outro código por tentativa.' }
$guid=[Guid]::Empty
if (![Guid]::TryParse($identity.host_id,[ref]$guid) -or $identity.token -notmatch '^[0-9a-f]{64}$') { throw 'Resposta de cadastro inválida.' }
Write-Json (Join-Path $Root 'config/identity.json') @{host_id=$guid.ToString();token=$identity.token}
Set-PrivateAcl $Root
Remove-Item -LiteralPath $pending -Force
