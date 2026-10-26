$script:WUOValidModes = @('Off', 'ReportOnly', 'Remediate', 'RemediateAndFallback')

function ConvertTo-WUOConfig {
    <#
    .SYNOPSIS
        Turns raw registry values into a validated config object.
        Missing or invalid values fall back to safe defaults; an invalid Mode becomes ReportOnly.
    #>
    [CmdletBinding()]
    param([hashtable]$Raw = @{})

    $cfg = [ordered]@{
        Mode                = 'ReportOnly'
        FallbackGraceDays   = 3
        FallbackMaxAttempts = 3
        MinFreeDiskGB       = 20
        ResetCooldownDays   = 7
        SyncStaleHours      = 24
        ScanStaleDays       = 7
        FixMaxRepeats       = 3
        FixServices         = $true
        FixPauses           = $true
        FixPolicyKeys       = $true
        FixSyncAndCleanup   = $true
        # Off by default: the reset wipes the Windows Update history list (installed updates stay installed).
        FixResetStack       = $false
        # Lets the Remediate mode install overdue approved quality updates (the standalone Remediations package
        # turns it on; RemediateAndFallback always installs).
        InstallOverdueUpdates = $false
        Warnings            = @()
    }

    $warnings = New-Object System.Collections.Generic.List[string]

    if ($Raw.ContainsKey('Mode')) {
        $match = $script:WUOValidModes | Where-Object { $_ -ieq [string]$Raw['Mode'] }
        if ($match) { $cfg.Mode = $match }
        else { $warnings.Add("Invalid Mode '$($Raw['Mode'])'; using ReportOnly") }
    }

    $intRules = @{
        FallbackGraceDays   = @(0, 30)
        FallbackMaxAttempts = @(1, 10)
        MinFreeDiskGB       = @(1, 500)
        ResetCooldownDays   = @(1, 90)
        SyncStaleHours      = @(1, 720)
        ScanStaleDays       = @(1, 90)
        FixMaxRepeats       = @(1, 10)
    }
    foreach ($name in $intRules.Keys) {
        if (-not $Raw.ContainsKey($name)) { continue }
        $n = 0
        $lo, $hi = $intRules[$name]
        if ([int]::TryParse([string]$Raw[$name], [ref]$n) -and $n -ge $lo -and $n -le $hi) { $cfg[$name] = $n }
        else { $warnings.Add("Invalid $name '$($Raw[$name])'; using default $($cfg[$name])") }
    }

    foreach ($name in 'FixServices', 'FixPauses', 'FixPolicyKeys', 'FixSyncAndCleanup', 'FixResetStack', 'InstallOverdueUpdates') {
        if (-not $Raw.ContainsKey($name)) { continue }
        $v = [string]$Raw[$name]
        if ($v -in '0', '1') { $cfg[$name] = ($v -eq '1') }
        else { $warnings.Add("Invalid $name '$v'; using default") }
    }

    $cfg.Warnings = $warnings.ToArray()
    [pscustomobject]$cfg
}

function Get-WUOConfig {
    <#
    .SYNOPSIS
        Reads HKLM:\SOFTWARE\IntuneWUO (or -Path) and returns the validated config.
    #>
    [CmdletBinding()]
    param([string]$Path = 'HKLM:\SOFTWARE\IntuneWUO')

    $raw = @{}
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        foreach ($name in $key.GetValueNames()) {
            if ($name) { $raw[$name] = $key.GetValue($name) }
        }
    }
    ConvertTo-WUOConfig -Raw $raw
}
