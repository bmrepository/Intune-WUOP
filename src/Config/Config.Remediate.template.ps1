<#
.SYNOPSIS
    Remediation half of an IntuneWUO-Config package. Writes the mode and settings stamped in by the build.
#>
$key = 'HKLM:\SOFTWARE\IntuneWUO'
$desired = @{
__SETTINGS__
}

if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
foreach ($name in $desired.Keys) {
    $value = $desired[$name]
    if ($value -is [int]) { Set-ItemProperty -LiteralPath $key -Name $name -Value $value -Type DWord }
    else { Set-ItemProperty -LiteralPath $key -Name $name -Value ([string]$value) -Type String }
}
Write-Output 'IntuneWUO config written'
exit 0
