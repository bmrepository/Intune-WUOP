<#
.SYNOPSIS
    Detection half of an IntuneWUO-Config Remediation. The build stamps __MODE__ (and optional
    settings) for each mode package. Exit 1 means "the registry does not match this package".
#>
$key = 'HKLM:\SOFTWARE\IntuneWUO'
$desired = @{
__SETTINGS__
}

if (-not (Test-Path -LiteralPath $key)) { Write-Output 'IntuneWUO key missing'; exit 1 }
$item = Get-Item -LiteralPath $key
foreach ($name in $desired.Keys) {
    if ([string]$item.GetValue($name) -ne [string]$desired[$name]) {
        Write-Output "Mismatch: $name"
        exit 1
    }
}
Write-Output 'IntuneWUO config in place'
exit 0
