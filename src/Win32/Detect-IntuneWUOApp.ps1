<#
.SYNOPSIS
    Win32 app custom detection rule. Prints a value and exits 0 only if the installed version matches and
    the fallback task exists. The expected version is stamped in by the build.
#>
$expected = '__VERSION__'
$dir = Join-Path $env:ProgramFiles 'IntuneWUO'
$versionFile = Join-Path $dir 'version.txt'

if (-not (Test-Path -LiteralPath $versionFile)) { exit 1 }
if ((Get-Content -LiteralPath $versionFile -Raw).Trim() -ne $expected) { exit 1 }
if (-not (Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -ErrorAction SilentlyContinue)) { exit 1 }

Write-Output "IntuneWUO $expected installed"
exit 0
