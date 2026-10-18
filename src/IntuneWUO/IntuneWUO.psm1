Set-StrictMode -Version 2.0

foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction Stop) {
    . $file.FullName
}
