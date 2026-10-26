# HTTPS redirects are followed manually and never downgraded. Hash must come from a trusted release channel.
function Get-VerifiedArtifact([string]$Url,[string]$Sha256,[string]$OutFile) {
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'SHA256 obrigatório.' }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $current=$Url
    for ($redirect=0;$redirect -le 5;$redirect++) {
        $uri=[Uri]$current;if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Artefatos exigem HTTPS sem credenciais na URL.' }
        $req=[Net.HttpWebRequest]::Create($uri);$req.AllowAutoRedirect=$false;$req.Timeout=60000;$req.ReadWriteTimeout=60000
        $res=$req.GetResponse()
        try {
            $status=[int]$res.StatusCode
            if ($status -in @(301,302,303,307,308)) { $current=([Uri]::new($uri,$res.Headers['Location'])).AbsoluteUri;continue }
            if ($status -ne 200) { throw 'Falha no download de artefato.' }
            $input=$res.GetResponseStream();$output=[IO.File]::Create($OutFile)
            try {
                $buffer=New-Object byte[] 65536;$total=0
                while (($n=$input.Read($buffer,0,$buffer.Length)) -gt 0) { $total+=$n;if ($total -gt 52428800) { throw 'Artefato excede 50 MB.' };$output.Write($buffer,0,$n) }
            } finally { $input.Dispose();$output.Dispose() }
            if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ine $Sha256) { Remove-Item -LiteralPath $OutFile -Force;throw 'SHA256 divergente; artefato descartado.' }
            return
        } finally { $res.Dispose() }
    }
    throw 'Redirecionamentos em excesso.'
}
function Expand-SafePackage([string]$Zip,[string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory($Destination)
    $base=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $size=0;if ($archive.Entries.Count -gt 1000) { throw 'Pacote com arquivos em excesso.' }
        foreach ($entry in $archive.Entries) {
            $full=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            $size+=$entry.Length
            if (!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':') -or $size -gt 104857600) { throw 'Caminho ou tamanho de pacote inválido.' }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$Destination)
}
