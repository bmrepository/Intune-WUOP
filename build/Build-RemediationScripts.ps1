<#
.SYNOPSIS
    Generates the two self-contained Intune Remediations scripts in remediation\.
.DESCRIPTION
    remediation\Detect-IntuneWUO.ps1     detection script (upload as "Detection script file")
    remediation\Remediate-IntuneWUO.ps1  remediation script (upload as "Remediation script file")
    Each one embeds the whole src\IntuneWUO module plus the settings block from src\Standalone\Settings.ps1,
    so devices need nothing installed first. Output is ASCII-only UTF-8 without a BOM. A Pester test fails
    if the committed files are out of date, so run this after any change under src\IntuneWUO or src\Standalone.
.EXAMPLE
    .\build\Build-RemediationScripts.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param-block defaults under 'powershell -File' on 5.1, so resolve it here.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = (Resolve-Path (Join-Path $here '..')).Path
if (-not $OutDir) { $OutDir = Join-Path $repo 'remediation' }
$src = Join-Path $repo 'src'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$version = ([regex]::Match((Get-Content -LiteralPath (Join-Path $src 'IntuneWUO\IntuneWUO.psd1') -Raw), "ModuleVersion\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $version) { throw 'ModuleVersion not found in IntuneWUO.psd1.' }

# Same files, same order as IntuneWUO.psm1 dot-sources them.
$engine = (Get-ChildItem -LiteralPath (Join-Path $src 'IntuneWUO\Public') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    "# ---- $($_.Name) ----`n" + (Get-Content -LiteralPath $_.FullName -Raw).Replace("`r`n", "`n").TrimEnd()
}) -join "`n`n"
$settings = (Get-Content -LiteralPath (Join-Path $src 'Standalone\Settings.ps1') -Raw).Replace("`r`n", "`n").TrimEnd()

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$pairs = @(
    @{ Template = 'Detect.template.ps1'; Out = 'Detect-IntuneWUO.ps1' }
    @{ Template = 'Remediate.template.ps1'; Out = 'Remediate-IntuneWUO.ps1' }
)
foreach ($p in $pairs) {
    $text = (Get-Content -LiteralPath (Join-Path $src "Standalone\$($p.Template)") -Raw).Replace("`r`n", "`n")
    # String.Replace, not -replace: the engine contains '$' sequences a regex replacement would rewrite.
    $text = $text.Replace('#__SETTINGS__', $settings).Replace('#__ENGINE__', $engine).Replace('__VERSION__', $version)
    $text = $text.TrimEnd() + "`n"
    $bad = [regex]::Matches($text, '[^\x09\x0A\x0D\x20-\x7E]')
    if ($bad.Count -gt 0) { throw "$($p.Out): $($bad.Count) non-ASCII character(s), first at index $($bad[0].Index)." }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($errs) { throw "$($p.Out): parse error: $($errs[0].Message)" }
    $path = Join-Path $OutDir $p.Out
    [IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host ("{0}  {1:N0} bytes  v{2}" -f $path, $text.Length, $version)
}
