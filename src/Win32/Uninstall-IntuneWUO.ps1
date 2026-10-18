<#
.SYNOPSIS
    Win32 app uninstall script: removes the scheduled task, the program folder and the event log.
    The HKLM:\SOFTWARE\IntuneWUO key is kept for audit; remove it manually if wanted.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'IntuneWUO')
)

$ErrorActionPreference = 'Continue'

$task = Get-ScheduledTask -TaskPath '\IntuneWUO\' -TaskName 'IntuneWUO-Fallback' -ErrorAction SilentlyContinue
if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }

if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }

if ([System.Diagnostics.EventLog]::SourceExists('IntuneWUO')) { Remove-EventLog -LogName 'IntuneWUO' }
exit 0
