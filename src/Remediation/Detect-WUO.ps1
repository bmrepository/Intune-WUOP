<#
.SYNOPSIS
    Intune Remediation detection script for Intune-WUO.
.DESCRIPTION
    Reads the config, collects device state, evaluates findings, logs them and prints a one-line
    status for Intune. Read-only: it never changes the device.

    Exit codes (Intune Remediations):
      0 = nothing for the remediation script to do (compliant, Off, ReportOnly, or nothing fixable)
      1 = a finding exists that the mode and Fix* switches allow the remediation script to fix
.NOTES
    Run as SYSTEM in 64-bit PowerShell. Keep ASCII-only and UTF-8 without BOM.
#>
[CmdletBinding()]
param(
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'

try {
    if (-not $ModulePath) {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'IntuneWUO\Module\IntuneWUO.psd1'),
            (Join-Path $PSScriptRoot '..\IntuneWUO\IntuneWUO.psd1')
        )
        $ModulePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $ModulePath) { throw 'IntuneWUO module not found.' }
    Import-Module $ModulePath -Force

    $config = Get-WUOConfig
    foreach ($w in $config.Warnings) { Write-WUOLog -Level Warning -Component 'Detect' -Message $w }

    if ($config.Mode -eq 'Off') {
        Write-WUOLog -Component 'Detect' -Message 'Mode is Off; nothing to do.'
        Write-WUOEvent -Id (Get-WUOEventId -Kind RunOff) -Message 'Mode is Off; detection skipped.'
        Write-Output (Format-WUOStatus -Config $config -Disabled)
        exit 0
    }

    $state = Get-WUOState
    $findings = @(Get-WUOFinding -State $state -Config $config)

    foreach ($key in $state.CollectionErrors.Keys) {
        Write-WUOLog -Level Warning -Component 'Detect' -Message "State collection failed for ${key}: $($state.CollectionErrors[$key])"
    }
    Write-WUOLog -Component 'Detect' -Message "Run complete in mode $($config.Mode): $($findings.Count) finding(s)." -Data @{
        findings = @($findings | ForEach-Object { @{ id = $_.Id; severity = $_.Severity; autoFix = $_.AutoFix } })
        build    = $state.OS.Build
    }
    Write-WUOEvent -Id (Get-WUOEventId -Kind RunComplete) -Message ("Mode {0}; findings: {1}" -f $config.Mode, (($findings | ForEach-Object Id) -join ', '))
    foreach ($f in $findings | Where-Object { $_.Severity -ne 'Info' }) {
        Write-WUOEvent -Id (Get-WUOEventId -Kind Finding -FindingId $f.Id) -EntryType Warning -Message "$($f.Id): $($f.Message)"
    }

    Write-Output (Format-WUOStatus -Config $config -Findings $findings -Build $state.OS.Build)

    $canRemediate = $config.Mode -in 'Remediate', 'RemediateAndFallback'
    $fixable = @($findings | Where-Object { Test-WUOFixEnabled -Finding $_ -Config $config })
    if ($canRemediate -and $fixable.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    # A detection failure must not trigger remediation.
    try {
        Write-WUOLog -Level Error -Component 'Detect' -Message $_.Exception.Message
        Write-WUOEvent -Id 9000 -EntryType Error -Message $_.Exception.Message
    } catch { }
    Write-Output ('WUO|v1|Error|{0}' -f $_.Exception.Message)
    exit 0
}
