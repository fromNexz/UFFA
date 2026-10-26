Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Assert-Admin {
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Requer Windows com PowerShell 5.1 ou superior.' }
    $who=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($who)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute como administrador.' }
    $release=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release
    if ($release -lt 461808) { throw 'Instale .NET Framework 4.7.2 ou superior.' }
}
function Set-PrivateAcl([string]$Path) {
    $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $items=@(Get-Item -LiteralPath $Path)+@(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A raiz não pode conter junctions ou links simbólicos.' }
        if ($item.PSIsContainer) {
            $acl=New-Object Security.AccessControl.DirectorySecurity
            $flags=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
            foreach ($sid in @($system,$admins)) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$flags,'None','Allow')) }
        } else {
            $acl=New-Object Security.AccessControl.FileSecurity
            foreach ($sid in @($system,$admins)) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow')) }
        }
        $acl.SetAccessRuleProtection($true,$false)
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}
function Write-Json([string]$Path,$Value) {
    $tmp="$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $b=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 30))
        $f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $f.Write($b,0,$b.Length);$f.Flush($true) } finally { $f.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp,$Path,[NullString]::Value) } else { [IO.File]::Move($tmp,$Path) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Read-Json([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Assert-Package([string]$PackageRoot) {
    $base=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')+'\'
    $manifest=Read-Json (Join-Path $PackageRoot 'manifest.json')
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Versão de pacote inválida.' }
    foreach ($file in $manifest.files) {
        $full=[IO.Path]::GetFullPath((Join-Path $PackageRoot $file.path))
        if (!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or $file.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Manifesto inválido.' }
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $file.sha256) { throw "Integridade inválida: $($file.path)" }
    }
    $exe=Join-Path $PackageRoot 'bin/InfraMonitor.Agent.exe'
    $v= & $exe --version
    if ($LASTEXITCODE -ne 0 -or $v -ne $manifest.version) { throw 'Versão do executável diverge do manifesto.' }
    return $manifest
}
function Invoke-Sc([string[]]$Arguments) {
    & sc.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha em sc.exe ($($Arguments[0]))." }
}
function Wait-AgentHealthy([string]$Root,[string]$Version,[int]$Seconds=90) {
    $limit=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $svc=Get-Service InfraMonitorAgent -ErrorAction SilentlyContinue
        $health=Join-Path $Root 'state/health.json'
        if ($svc -and $svc.Status -eq 'Running' -and (Test-Path $health)) {
            $h=Read-Json $health
            if ($h.version -eq $Version -and ([DateTime]::UtcNow-[DateTime]::Parse($h.last_success_at).ToUniversalTime()).TotalSeconds -lt 90) { return }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $limit)
    throw 'Serviço não confirmou heartbeat autenticado. Verifique API, identidade e logs; nenhuma credencial foi recriada.'
}
function Get-IdentityFromLegacy([string]$Directory) {
    # Only explicit formats; never guess which host/token pair belongs to this machine.
    $uuid=Join-Path $Directory 'host.uuid';$token=Join-Path $Directory 'host.token';$json=Join-Path $Directory 'config/identity.json'
    if ((Test-Path $uuid) -and (Test-Path $token)) { $id=([IO.File]::ReadAllText($uuid)).Trim();$secret=([IO.File]::ReadAllText($token)).Trim() }
    elseif (Test-Path $json) { $old=Read-Json $json;$id=$old.host_id;$secret=$old.token }
    else { throw 'Identidade não encontrada. Informe diretório contendo host.uuid + host.token ou config/identity.json.' }
    $parsed=[Guid]::Empty
    if (![Guid]::TryParse($id,[ref]$parsed) -or $secret.Length -lt 32) { throw 'Identidade antiga inválida; não foi alterada.' }
    return @{host_id=$parsed.ToString();token=$secret}
}
