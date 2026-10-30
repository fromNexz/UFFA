# Pure configuration transformation: no service/process control and no network.
function ConvertTo-MonitoringOnlyCatalog($Catalog) {
    $result=@()
    foreach ($entry in @($Catalog)) {
        $protected=$false
        foreach ($name in @('id','service_name','executable','process_name')) {
            if ($entry.PSObject.Properties[$name]) {
                $value=[string]$entry.$name
                if ($value -match '(?i)frcaixa|(?:^|[\\/])monitor\.exe$') { $protected=$true }
            }
        }
        if ($protected) { continue }
        $copy=ConvertFrom-Json (ConvertTo-Json -InputObject $entry -Depth 20)
        $copy|Add-Member -NotePropertyName allowed_operations -NotePropertyValue @() -Force
        $copy|Add-Member -NotePropertyName allow_force -NotePropertyValue $false -Force
        $result+=$copy
    }
    $result+=[pscustomobject]@{id='frcaixa';kind='process';process_name='monitor.exe';allowed_operations=@();allow_force=$false;health_tcp_port=$null}
    return ,$result
}
