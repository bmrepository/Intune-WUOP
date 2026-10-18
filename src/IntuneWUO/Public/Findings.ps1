function Get-WUOStateValue {
    # Reads $Name from a hashtable/dictionary or from an object's property; $null when absent.
    param($Source, [string]$Name)
    if ($null -eq $Source) { return $null }
    if ($Source -is [System.Collections.IDictionary]) { if ($Source.Contains($Name)) { return $Source[$Name] } else { return $null } }
    $prop = $Source.PSObject.Properties[$Name]
    if ($prop) { $prop.Value } else { $null }
}
function New-WUOFinding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Info', 'Warning', 'Critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        # Which Fix* switch would cover an automatic fix. 'None' means report-only.
        [ValidateSet('None', 'Services', 'Pauses', 'PolicyKeys', 'SyncAndCleanup')][string]$AutoFix = 'None',
        [string]$Source = ''
    )
    [pscustomobject]@{ Id = $Id; Severity = $Severity; Message = $Message; AutoFix = $AutoFix; Source = $Source }
}

function Get-WUOFinding {
    <#
    .SYNOPSIS
        Pure evaluation: turns a state (see Get-WUOState) and a config into findings. No I/O.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [datetime]$Now = (Get-Date)
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $pm = if ($State.PolicyManager) { $State.PolicyManager } else { @{} }
    $gpo = if ($State.Gpo) { $State.Gpo } else { @{} }
    $gpoAu = if ($State.GpoAU) { $State.GpoAU } else { @{} }

    # Values Windows Autopatch itself flags as conflicting (any value counts).
    $conflicts = @(
        @{ Id = 'POLICY_CONFLICT_DONOTCONNECT'; Table = $gpo;   Name = 'DoNotConnectToWindowsUpdateInternetLocations' }
        @{ Id = 'POLICY_CONFLICT_DISABLEWUACCESS'; Table = $gpo; Name = 'DisableWindowsUpdateAccess' }
        @{ Id = 'POLICY_CONFLICT_NOAUTOUPDATE'; Table = $gpoAu; Name = 'NoAutoUpdate' }
    )
    foreach ($c in $conflicts) {
        if ($c.Table.ContainsKey($c.Name)) {
            # Source (domain GPO vs local policy) is not attributed yet, so nothing here is auto-fixable.
            $findings.Add((New-WUOFinding -Id $c.Id -Severity Critical -Source 'Unknown' `
                -Message "Policy value '$($c.Name)' is set ($($c.Table[$c.Name])); Windows Autopatch flags this as a conflict."))
        }
    }

    $wsus = ($gpo['UseWUServer'] -eq 1) -or $gpo['WUServer'] -or $gpo['UpdateServiceUrl'] -or $pm['UpdateServiceUrl'] -or $gpoAu['UseWUServer'] -eq 1
    if ($wsus) {
        $findings.Add((New-WUOFinding -Id 'WSUS_REMNANT' -Severity Warning -Source 'Unknown' `
            -Message 'An intranet update service (WSUS) is configured.'))
        if ($gpo['DisableDualScan'] -eq 1 -or $pm['DisableDualScan'] -eq 1) {
            $findings.Add((New-WUOFinding -Id 'DUALSCAN_CONFLICT' -Severity Critical `
                -Message 'WSUS is configured and DisableDualScan is on; the device cannot scan Windows Update.'))
        }
    }

    foreach ($s in @($State.Services)) {
        if ($s.StartMode -eq 'Disabled') {
            $sev = if ($s.Name -in 'wuauserv', 'UsoSvc', 'wlidsvc') { 'Critical' } else { 'Warning' }
            $findings.Add((New-WUOFinding -Id "SVC_DISABLED_$($s.Name)" -Severity $sev -AutoFix Services `
                -Message "Service $($s.Name) is disabled."))
        }
    }

    # A pause set by Intune policy is deliberate and is never treated as a fault.
    $policyPause = ($pm['PauseQualityUpdates'] -eq 1) -or $pm['PauseQualityUpdatesStartTime']
    $policyFeaturePause = ($pm['PauseFeatureUpdates'] -eq 1) -or $pm['PauseFeatureUpdatesStartTime']
    $ups = if ($State.UpdatePolicySettings) { $State.UpdatePolicySettings } else { @{} }
    if ($ups['PausedQualityStatus'] -and -not $policyPause) {
        $findings.Add((New-WUOFinding -Id 'PAUSE_QUALITY_USER' -Severity Warning -AutoFix Pauses -Source 'User' `
            -Message 'Quality updates are paused, but not by policy.'))
    }
    if ($ups['PausedFeatureStatus'] -and -not $policyFeaturePause) {
        $findings.Add((New-WUOFinding -Id 'PAUSE_FEATURE_USER' -Severity Warning -AutoFix Pauses -Source 'User' `
            -Message 'Feature updates are paused, but not by policy.'))
    }
    if ($policyPause) {
        $findings.Add((New-WUOFinding -Id 'PAUSE_POLICY' -Severity Info -Source 'Policy' `
            -Message 'Quality updates are paused by policy (informational; never changed).'))
    }

    $telemetry = if ($State.PolicyManagerSystem -and $null -ne $State.PolicyManagerSystem['AllowTelemetry']) {
        $State.PolicyManagerSystem['AllowTelemetry']
    } elseif ($State.GpoDataCollection) { $State.GpoDataCollection['AllowTelemetry'] } else { $null }
    if ($null -ne $telemetry -and [int]$telemetry -lt 1) {
        $findings.Add((New-WUOFinding -Id 'DIAGDATA_LOW' -Severity Warning `
            -Message 'Diagnostic data is below Required; Windows Autopatch needs Required or higher.'))
    }

    if ($State.LastSync -and ($Now - $State.LastSync).TotalHours -gt $Config.SyncStaleHours) {
        $findings.Add((New-WUOFinding -Id 'SYNC_STALE' -Severity Warning -AutoFix SyncAndCleanup `
            -Message "Last MDM sync was more than $($Config.SyncStaleHours) hours ago."))
    }

    $scan = if ($State.Wua) { $State.Wua['LastSearchSuccess'] } else { $null }
    if ($scan -and $scan.Year -gt 2000 -and ($Now - $scan).TotalDays -gt $Config.ScanStaleDays) {
        # AutoFix Services covers the update-stack reset (rate-limited by ResetCooldownDays).
        $findings.Add((New-WUOFinding -Id 'SCAN_STALE' -Severity Warning -AutoFix Services `
            -Message "No successful Windows Update scan in $($Config.ScanStaleDays) days."))
    }

    if ($null -ne $State.DiskFreeGB -and $State.DiskFreeGB -lt $Config.MinFreeDiskGB) {
        $findings.Add((New-WUOFinding -Id 'DISK_LOW' -Severity Warning -AutoFix SyncAndCleanup `
            -Message "Free disk space is $($State.DiskFreeGB) GB (threshold $($Config.MinFreeDiskGB) GB)."))
    }

    if ($State.Reboot -and ($State.Reboot['CBS'] -or $State.Reboot['WU'])) {
        $findings.Add((New-WUOFinding -Id 'RESTART_PENDING' -Severity Info `
            -Message 'A restart is pending (left to the native deadline and grace settings).'))
    }

    if ($State.ConfigMgr -and $State.ConfigMgr['Present']) {
        $findings.Add((New-WUOFinding -Id 'CONFIGMGR_PRESENT' -Severity Info `
            -Message 'ConfigMgr client present; confirm the Windows Update workload is on Intune.'))
    }

    # Autopatch's own verdict. A missing broker is informational: it is optional and not on every device.
    $ap = if ($State.Contains('Autopatch')) { $State['Autopatch'] } else { $null }
    if ($ap -and (Get-WUOStateValue $ap 'BrokerPresent')) {
        $bitmask = Get-WUOStateValue $ap 'ResultsBitmask'
        if (($null -ne $bitmask -and [int64]$bitmask -ne 0) -or @(Get-WUOStateValue $ap 'ErrorCodes').Count -gt 0) {
            $findings.Add((New-WUOFinding -Id 'AUTOPATCH_READINESS_FAILED' -Severity Warning `
                -Message ("Autopatch device readiness failed (ResultsBitmask={0}, ErrorCodes={1})." -f $bitmask, (@(Get-WUOStateValue $ap 'ErrorCodes') -join ';'))))
        }
        $readinessAt = Get-WUOStateValue $ap 'ReadinessAt'
        if ($readinessAt -and ($Now - [datetime]$readinessAt).TotalDays -gt 7) {
            $findings.Add((New-WUOFinding -Id 'AUTOPATCH_READINESS_STALE' -Severity Warning `
                -Message 'The Autopatch Client Broker has not reported device readiness for over 7 days.'))
        }
    }
    elseif ($ap) {
        $findings.Add((New-WUOFinding -Id 'AUTOPATCH_BROKER_ABSENT' -Severity Info `
            -Message 'The Windows Autopatch Client Broker is not installed; its readiness checks are unavailable.'))
    }

    $task = if ($State.Contains('FallbackTask')) { $State['FallbackTask'] } else { $null }
    if ($Config.Mode -eq 'RemediateAndFallback' -and $task) {
        if (-not (Get-WUOStateValue $task 'Present') -or -not (Get-WUOStateValue $task 'Enabled')) {
            $findings.Add((New-WUOFinding -Id 'FALLBACK_TASK_MISSING' -Severity Warning -AutoFix Services `
                -Message 'The fallback scheduled task is missing or disabled.'))
        }
    }

    $hp = $State.Hotpatch
    if ($hp -and $hp['Enrolled']) {
        if ($State.OS -and $State.OS.Build -lt 26100) {
            $findings.Add((New-WUOFinding -Id 'HOTPATCH_UNSUPPORTED_OS' -Severity Warning `
                -Message 'Hotpatch needs Windows 11 24H2 (build 26100) or later.'))
        }
        if ($State.DeviceGuard -and $State.DeviceGuard['VBSStatus'] -ne 2) {
            $findings.Add((New-WUOFinding -Id 'HOTPATCH_VBS_NOT_RUNNING' -Severity Warning `
                -Message 'Hotpatch needs virtualization-based security running. Fix with the VirtualizationBasedTechnology policy.'))
        }
        if ($State.OS -and $State.OS.Arch -eq 'ARM64' -and $hp['HotPatchRestrictions'] -ne 1) {
            $findings.Add((New-WUOFinding -Id 'HOTPATCH_CHPE_ENABLED' -Severity Warning `
                -Message 'Hotpatch on Arm64 needs CHPE disabled. Fix with the DisableCHPE policy.'))
        }
    }

    $findings.ToArray()
}
