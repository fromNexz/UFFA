# Configuration only. Does not stop applications, delete files or change credentials.
function Get-FrCaixaExecutable($Catalog) {
    foreach ($entry in @($Catalog)) {
        if ($entry.id -eq 'frcaixa' -and $entry.PSObject.Properties['executable'] -and $entry.executable) { return [string]$entry.executable }
    }
    $paths=@(Get-CimInstance Win32_Process -Filter "Name='monitor.exe'" | Where-Object { $_.ExecutablePath } | Select-Object -ExpandProperty ExecutablePath -Unique)
    if ($paths.Count -eq 1) { return [string]$paths[0] }
    if ($paths.Count -gt 1) { throw 'Mais de um caminho de monitor.exe. Configure o executavel FrCaixa local antes de habilitar controle.' }
    return 'C:\FrCaixaMonitor\monitor.exe'
}
function ConvertTo-RemoteMaintenanceCatalog($Catalog,[string]$FrCaixaExecutable) {
    if ($FrCaixaExecutable -notmatch '^[A-Za-z]:\\[^"\r\n]+\.exe$' -or $FrCaixaExecutable.Contains('..')) { throw 'Caminho FrCaixa absoluto local invalido.' }
    $result=@();$frHealth=$null
    foreach ($old in @($Catalog)) { if ($old.id -eq 'frcaixa' -and $old.PSObject.Properties['health_tcp_port']) { $frHealth=$old.health_tcp_port } }
    foreach ($entry in @($Catalog)) {
        if ($entry.id -in @('frcaixa','rustdesk','system_cleanup')) { continue }
        $copy=ConvertFrom-Json (ConvertTo-Json -InputObject $entry -Depth 20)
        $copy|Add-Member -NotePropertyName allowed_operations -NotePropertyValue @() -Force
        $copy|Add-Member -NotePropertyName allow_force -NotePropertyValue $false -Force
        $result+=$copy
    }
    $result+=[pscustomobject]@{id='frcaixa';kind='process';process_name='monitor.exe';executable=$FrCaixaExecutable;remote_control_enabled=$true;allowed_operations=@('start','stop','restart','kill');allow_force=$true;health_tcp_port=$frHealth}
    $result+=[pscustomobject]@{id='rustdesk';kind='process';executable='C:\Program Files\RustDesk\RustDesk.exe';remote_control_enabled=$true;allowed_operations=@('start','stop','restart','kill');allow_force=$true;health_tcp_port=$null}
    $result+=[pscustomobject]@{id='system_cleanup';kind='process';remote_control_enabled=$true;allowed_operations=@('start');allow_force=$false;health_tcp_port=$null}
    return ,$result
}
