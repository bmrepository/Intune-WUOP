<#
.SYNOPSIS
    Intune Remediation remediation script for Intune-WUO.
.DESCRIPTION
    Runs only after Detect-WUO.ps1 exits 1. Re-collects state (so it acts on current facts), applies the
    fixes the mode and Fix* switches allow, logs before/after, and prints a one-line summary.

    Exit codes: 0 = everything attempted succeeded or was legitimately skipped; 1 = at least one fix failed.
.NOTES
    Run as SYSTEM in 64-bit PowerShell. Keep ASCII-only and UTF-8 without BOM.
#>
[CmdletBinding()]
param(
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'
$lock = $null

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
    if ($config.Mode -notin 'Remediate', 'RemediateAndFallback') {
        Write-WUOLog -Component 'Remediate' -Message "Mode is $($config.Mode); not remediating."
        Write-Output "WUO|v1|NoAction|Mode=$($config.Mode)"
        exit 0
    }

    $lock = Enter-WUOLock
    if (-not $lock) {
        Write-WUOLog -Component 'Remediate' -Message 'Another IntuneWUO run holds the lock; exiting.'
        Write-Output 'WUO|v1|NoAction|Busy'
        exit 0
    }

    $state = Get-WUOState
    $findings = @(Get-WUOFinding -State $state -Config $config)

    # The install folder is the parent of the module folder; needed to re-register the fallback task.
    $installDir = Split-Path -Parent (Split-Path -Parent $ModulePath)
    $actions = Get-WUODefaultActions
    $actions['RegisterTask'] = { param($f) Register-WUOFallbackTask -InstallDir $installDir; "Registered fallback task from $installDir" }.GetNewClosure()

    $results = @(Invoke-WUORemediation -Findings $findings -Config $config -Actions $actions)

    foreach ($r in $results) {
        $level = if ($r.Outcome -eq 'Failed') { 'Error' } elseif ($r.Outcome -eq 'Suppressed') { 'Warning' } else { 'Info' }
        Write-WUOLog -Level $level -Component 'Remediate' -Message "$($r.Id): $($r.Outcome) $($r.Reason) $($r.Detail)".Trim() `
            -Data @{ id = $r.Id; outcome = $r.Outcome; reason = $r.Reason }
        if ($r.Outcome -eq 'Fixed') {
            Write-WUOEvent -Id (Get-WUOEventId -Kind Fix -FindingId $r.Id) -Message "$($r.Id) fixed: $($r.Detail)"
        }
        elseif ($r.Outcome -eq 'Failed') {
            Write-WUOEvent -Id (Get-WUOEventId -Kind FixFailed -FindingId $r.Id) -EntryType Error -Message "$($r.Id) fix failed: $($r.Detail)"
        }
    }

    $fixed = @($results | Where-Object Outcome -eq 'Fixed' | ForEach-Object Id)
    $failed = @($results | Where-Object Outcome -eq 'Failed' | ForEach-Object Id)
    $suppressed = @($results | Where-Object Outcome -eq 'Suppressed' | ForEach-Object Id)
    $out = 'WUO|v1|Remediated|Fixed={0}|Failed={1}|Suppressed={2}' -f ($fixed -join ','), ($failed -join ','), ($suppressed -join ',')
    if ($out.Length -gt 2048) { $out = $out.Substring(0, 2048) }
    Write-Output $out

    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    try {
        Write-WUOLog -Level Error -Component 'Remediate' -Message $_.Exception.Message
        Write-WUOEvent -Id 9000 -EntryType Error -Message $_.Exception.Message
    } catch { }
    Write-Output ('WUO|v1|Error|{0}' -f $_.Exception.Message)
    exit 1
}
finally {
    if ($lock) { Exit-WUOLock -Mutex $lock }
}
