<#
.SYNOPSIS
    Assembles the Intune-WUO deployment artifacts under -OutDir.
.DESCRIPTION
    out\Win32\          staging folder for the Win32 app (module, fallback script, install/uninstall, ThirdParty)
    out\Win32-Detect\   the custom detection script for the Win32 app (version stamped)
    out\Remediation\    Detect-WUO.ps1 and Remediate-WUO.ps1
    out\Config\<Mode>\  one config Remediation package (Detect.ps1 / Remediate.ps1) per mode
    out\IntuneWUO.intunewin  only if -IntuneWinAppUtil is given
    Optionally pins PSWindowsUpdate (-PSWindowsUpdatePath, a folder holding the module version folder
    contents) and writes a SHA-256 manifest the devices verify before import. Nothing is downloaded.
.EXAMPLE
    .\build\Build-IntuneWUO.ps1 -Version 1.0.0 -PSWindowsUpdatePath C:\pinned\PSWindowsUpdate\2.2.1.5 -CertThumbprint <thumbprint>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutDir = (Join-Path $PSScriptRoot '..\out'),
    [string]$PSWindowsUpdatePath,
    [string]$CertThumbprint,
    [string]$IntuneWinAppUtil
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $repo 'src'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$OutDir = (New-Item -ItemType Directory -Path $OutDir -Force).FullName
$win32 = Join-Path $OutDir 'Win32'

# --- Win32 staging --------------------------------------------------------------------------------------
Copy-Item -LiteralPath (Join-Path $src 'IntuneWUO') -Destination (Join-Path $win32 'Module') -Recurse
foreach ($f in 'Invoke-WUOFallback.ps1', 'Install-IntuneWUO.ps1', 'Uninstall-IntuneWUO.ps1') {
    Copy-Item -LiteralPath (Join-Path $src "Win32\$f") -Destination $win32
}
Write-Utf8 (Join-Path $win32 'version.txt') $Version

# Stamp the module manifest version so the module and the app agree.
$psd1 = Join-Path $win32 'Module\IntuneWUO.psd1'
Write-Utf8 $psd1 ((Get-Content -LiteralPath $psd1 -Raw) -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion     = '$Version'")

# --- Pinned PSWindowsUpdate + manifest -----------------------------------------------------------------
if ($PSWindowsUpdatePath) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSWindowsUpdatePath 'PSWindowsUpdate.psd1'))) {
        throw "PSWindowsUpdate.psd1 not found in '$PSWindowsUpdatePath'."
    }
    $dest = Join-Path $win32 'ThirdParty\PSWindowsUpdate'
    Copy-Item -LiteralPath $PSWindowsUpdatePath -Destination $dest -Recurse
    $root = (Resolve-Path $dest).Path.TrimEnd('\')
    $files = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName) {
        $files[$f.FullName.Substring($root.Length + 1)] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    $manifest = [ordered]@{ schema = 1; module = 'PSWindowsUpdate'; builtAt = (Get-Date).ToString('o'); files = $files }
    Write-Utf8 (Join-Path $win32 'ThirdParty\manifest.json') ($manifest | ConvertTo-Json -Depth 4)
    Write-Host "Pinned PSWindowsUpdate: $($files.Count) file(s) hashed."
}
else {
    Write-Warning 'No -PSWindowsUpdatePath given: the package will use the native WUA COM backend only.'
}

# --- Remediation scripts -------------------------------------------------------------------------------
$rem = Join-Path $OutDir 'Remediation'
New-Item -ItemType Directory -Path $rem -Force | Out-Null
foreach ($f in 'Detect-WUO.ps1', 'Remediate-WUO.ps1') { Copy-Item -LiteralPath (Join-Path $src "Remediation\$f") -Destination $rem -Force }

# --- Win32 detection rule ------------------------------------------------------------------------------
$detectApp = (Get-Content -LiteralPath (Join-Path $src 'Win32\Detect-IntuneWUOApp.ps1') -Raw).Replace('__VERSION__', $Version)
Write-Utf8 (Join-Path $OutDir 'Win32-Detect\Detect-IntuneWUOApp.ps1') $detectApp

# --- Config packages (one per mode) --------------------------------------------------------------------
$detectT = Get-Content -LiteralPath (Join-Path $src 'Config\Config.Detect.template.ps1') -Raw
$remT = Get-Content -LiteralPath (Join-Path $src 'Config\Config.Remediate.template.ps1') -Raw
foreach ($mode in 'Off', 'ReportOnly', 'Remediate', 'RemediateAndFallback') {
    $settings = "    Mode = '$mode'"
    Write-Utf8 (Join-Path $OutDir "Config\$mode\Detect.ps1") $detectT.Replace('__SETTINGS__', $settings)
    Write-Utf8 (Join-Path $OutDir "Config\$mode\Remediate.ps1") $remT.Replace('__SETTINGS__', $settings)
}

# --- Optional signing ----------------------------------------------------------------------------------
if ($CertThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $CertThumbprint -and $_.HasPrivateKey } | Select-Object -First 1
    if (-not $cert) { throw "Code-signing certificate $CertThumbprint not found (with private key)." }
    $scripts = Get-ChildItem -LiteralPath $OutDir -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\ThirdParty\\' }
    foreach ($s in $scripts) {
        $r = Set-AuthenticodeSignature -FilePath $s.FullName -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
        if ($r.Status -ne 'Valid') { throw "Signing failed for $($s.Name): $($r.StatusMessage)" }
    }
    Write-Host "Signed $(@($scripts).Count) script(s)."
}

# --- Optional .intunewin -------------------------------------------------------------------------------
if ($IntuneWinAppUtil) {
    & $IntuneWinAppUtil -c $win32 -s 'Install-IntuneWUO.ps1' -o $OutDir -q | Out-Null
    $pkg = Join-Path $OutDir 'Install-IntuneWUO.intunewin'
    if (Test-Path -LiteralPath $pkg) { Move-Item -LiteralPath $pkg -Destination (Join-Path $OutDir 'IntuneWUO.intunewin') -Force }
    else { throw 'IntuneWinAppUtil did not produce a package.' }
}

Write-Host "Build $Version complete: $OutDir"
