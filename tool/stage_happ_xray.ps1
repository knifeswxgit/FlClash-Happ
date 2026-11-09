$ErrorActionPreference = 'Stop'
$version = 'v26.11.9'
$digest = '1262522266337b824f07beb8e1375786b437683b3890105469088f8e17e0a69d'
$archive = Join-Path ([System.IO.Path]::GetTempPath()) "FlClash-Xray-$([guid]::NewGuid()).zip"
$destination = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/xray'

try {
    Invoke-WebRequest "https://github.com/XTLS/Xray-core/releases/download/$version/Xray-windows-64.zip" -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $digest) {
        throw 'Xray archive SHA-256 mismatch'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bundle = [System.IO.Compression.ZipFile]::OpenRead($archive)
    try {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $files = @{'xray.exe' = 'FlClashXray.exe'; 'geoip.dat' = 'geoip.dat'; 'geosite.dat' = 'geosite.dat'; 'LICENSE' = 'LICENSE'}
        foreach ($source in $files.Keys) {
            $entry = $bundle.GetEntry($source)
            if ($null -eq $entry) { throw "Missing Xray asset $source" }
            $target = Join-Path $destination $files[$source]
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $bundle.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
}
