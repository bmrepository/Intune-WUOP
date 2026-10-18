<#
.SYNOPSIS
    Win32 app install script: copies the engine to %ProgramFiles%\IntuneWUO, locks the folder down,
    creates the event log and registers the fallback scheduled task.
.NOTES
    Run as SYSTEM in 64-bit PowerShell (use the Sysnative path from a 32-bit IME host).
    Layout expected next to this script (produced by build\Build-IntuneWUO.ps1):
      Module\            the IntuneWUO module
      ThirdParty\        pinned PSWindowsUpdate + manifest.json (optional)
      Invoke-WUOFallback.ps1, version.txt
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'IntuneWUO'),
    [ValidateSet('Bypass', 'AllSigned')][string]$ExecutionPolicy = 'Bypass'
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot

if (-not [Environment]::Is64BitProcess) { throw 'Run in 64-bit PowerShell.' }

if (Test-Path -LiteralPath $InstallDir) {
    # Replace the previous version; keep nothing from it (config and state live in the registry).
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

foreach ($item in 'Module', 'ThirdParty', 'Invoke-WUOFallback.ps1', 'version.txt') {
    $src = Join-Path $source $item
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $InstallDir -Recurse -Force }
}

# SYSTEM and Administrators full control, Users read/execute only: a standard user cannot alter what SYSTEM runs.
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }

Import-Module (Join-Path $InstallDir 'Module\IntuneWUO.psd1') -Force
Register-WUOEventSource
Register-WUOFallbackTask -InstallDir $InstallDir -ExecutionPolicy $ExecutionPolicy

Write-WUOLog -Component 'Install' -Message "Installed Intune-WUO $(Get-Content -LiteralPath (Join-Path $InstallDir 'version.txt') -ErrorAction SilentlyContinue) to $InstallDir"
exit 0
