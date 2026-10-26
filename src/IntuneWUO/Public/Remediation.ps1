function Test-WUOFixEnabled {
    <# True if the finding is auto-fixable and the config switch for its category is on. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Finding, [Parameter(Mandatory)]$Config)

    switch ($Finding.AutoFix) {
        'Services'       { return [bool]$Config.FixServices }
        'Pauses'         { return [bool]$Config.FixPauses }
        'PolicyKeys'     { return [bool]$Config.FixPolicyKeys }
        'SyncAndCleanup' { return [bool]$Config.FixSyncAndCleanup }
        'ResetStack'     { return [bool]$Config.FixResetStack }
        'Updates'        { return ($Config.Mode -eq 'RemediateAndFallback') -or [bool]$Config.InstallOverdueUpdates }
        default          { return $false }
    }
}

function Get-WUOFixActionName {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Finding)

    switch -Wildcard ($Finding.Id) {
        'SVC_DISABLED_*' { 'RepairService' }
        'PAUSE_*_USER'   { 'ClearPause' }
        'SYNC_STALE'     { 'TriggerSync' }
        'DISK_LOW'       { 'CleanupDisk' }
        'SCAN_STALE'     { 'ResetStack' }
        'FALLBACK_TASK_MISSING' { 'RegisterTask' }
        'UPDATE_OVERDUE' { 'InstallUpdates' }
        default          { $null }
    }
}

function Remove-WUOOldStackBackups {
    <#
    .SYNOPSIS
        Keeps only the newest SoftwareDistribution.bak-<stamp> / catroot2.bak-<stamp> backup in each parent folder and
        deletes the older ones, so repeated stack resets cannot fill the disk. Only folders whose names match
        exactly <base>.bak-<14 digits> are ever touched. Returns the paths it removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Parent,
        [string[]]$BaseName = @('SoftwareDistribution', 'catroot2'),
        [int]$Keep = 1
    )
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Parent) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($b in $BaseName) {
            $pattern = '^' + [regex]::Escape($b) + '\.bak-\d{14}$'
            $dirs = @(Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $pattern } | Sort-Object Name -Descending)
            foreach ($d in ($dirs | Select-Object -Skip $Keep)) {
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $removed.Add($d.FullName) }
                catch { }   # best effort: a locked old backup is not worth failing the reset
            }
        }
    }
    $removed.ToArray()
}
function Get-WUODefaultActions {
    <#
    .SYNOPSIS
        The real fix actions. Each takes the finding and returns a short description.
        A return value starting with 'SKIP:' means a precondition was not met (not counted as an attempt).
    #>
    [CmdletBinding()]
    param()

    @{
        RepairService = {
            param($Finding)
            $name = $Finding.Id -replace '^SVC_DISABLED_', ''
            $defaults = @{ wuauserv = 'Manual'; UsoSvc = 'Automatic'; BITS = 'Manual'; WaaSMedicSvc = 'Manual'; wlidsvc = 'Manual'; DiagTrack = 'Automatic' }
            if (-not $defaults.ContainsKey($name)) { throw "No default start type known for service '$name'." }
            Set-Service -Name $name -StartupType $defaults[$name] -ErrorAction Stop
            if ($defaults[$name] -eq 'Automatic') { Start-Service -Name $name -ErrorAction SilentlyContinue }
            "Set $name start type to $($defaults[$name])"
        }

        ClearPause = {
            param($Finding)
            # Only the user-pause values in the UX settings key; the system-owned status values are left alone.
            $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
            $names = if ($Finding.Id -eq 'PAUSE_FEATURE_USER') { @('PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime') }
            else { @('PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime') }
            $removed = @()
            foreach ($n in $names) {
                if ((Test-Path -LiteralPath $key) -and $null -ne (Get-Item -LiteralPath $key).GetValue($n)) {
                    Remove-ItemProperty -LiteralPath $key -Name $n -ErrorAction Stop
                    $removed += $n
                }
            }
            if ($removed.Count -eq 0) { return 'SKIP: no user pause values found' }
            'Removed ' + ($removed -join ', ')
        }

        TriggerSync = {
            param($Finding)
            $started = 0
            foreach ($e in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue) {
                if ((Get-Item -LiteralPath $e.PSPath).GetValue('ProviderID') -ne 'MS DM Server') { continue }
                $task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$($e.PSChildName)\" -TaskName 'PushLaunch' -ErrorAction SilentlyContinue
                if ($task) { Start-ScheduledTask -InputObject $task -ErrorAction Stop; $started++ }
            }
            if ($started -eq 0) { return 'SKIP: no MDM sync task found' }
            "Started $started MDM sync task(s)"
        }

        CleanupDisk = {
            param($Finding)
            $cutoff = (Get-Date).AddDays(-7)
            Get-ChildItem -LiteralPath (Join-Path $env:windir 'Temp') -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            $p = Start-Process -FilePath (Join-Path $env:windir 'System32\dism.exe') -WindowStyle Hidden -PassThru `
                -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup'
            if (-not $p.WaitForExit(20 * 60 * 1000)) { try { $p.Kill() } catch { }; throw 'Component cleanup timed out after 20 minutes.' }
            "Cleared old temp files and ran component cleanup (exit $($p.ExitCode))"
        }

        ResetStack = {
            param($Finding)
            if (Get-Process -Name TiWorker -ErrorAction SilentlyContinue) { return 'SKIP: an install is in progress' }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return 'SKIP: a restart is pending' }
            $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
            $services = 'wuauserv', 'bits', 'cryptsvc'
            foreach ($s in $services) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            try {
                $dirs = @((Join-Path $env:windir 'SoftwareDistribution'), (Join-Path $env:windir 'System32\catroot2'))
                foreach ($d in $dirs) {
                    if (Test-Path -LiteralPath $d) { Rename-Item -LiteralPath $d -NewName ((Split-Path $d -Leaf) + ".bak-$stamp") -ErrorAction Stop }
                }
            }
            finally {
                foreach ($s in $services) { Start-Service -Name $s -ErrorAction SilentlyContinue }
            }
            # Keep only the backup just made; older ones would otherwise accumulate (hundreds of MB per reset).
            $pruned = @(Remove-WUOOldStackBackups -Parent @($env:windir, (Join-Path $env:windir 'System32'))).Count
            "Reset Windows Update components (backups suffixed .bak-$stamp; pruned $pruned older backup folder(s))"
        }
    }
}

function Invoke-WUORemediation {
    <#
    .SYNOPSIS
        Applies the automatic fixes the mode and Fix* switches allow, with guardrails:
        - only findings marked auto-fixable are touched;
        - a fix that keeps being needed (FixMaxRepeats times within 7 days) is suppressed and reported;
        - the update-stack reset is rate-limited by ResetCooldownDays.
        Returns one result per auto-fixable finding: Id, Outcome (Fixed/Failed/Skipped/Suppressed), Reason, Detail.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Findings = @(),
        [Parameter(Mandatory)]$Config,
        [hashtable]$Actions,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State',
        [datetime]$Now = (Get-Date)
    )

    if (-not $Actions) { $Actions = Get-WUODefaultActions }
    $canAct = $Config.Mode -in 'Remediate', 'RemediateAndFallback'
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($f in $Findings) {
        if ($f.AutoFix -eq 'None') { continue }

        $r = [ordered]@{ Id = $f.Id; Outcome = 'Skipped'; Reason = ''; Detail = '' }
        $actionName = Get-WUOFixActionName -Finding $f

        if (-not $canAct) { $r.Reason = 'ModeNotRemediate' }
        elseif (-not (Test-WUOFixEnabled -Finding $f -Config $Config)) { $r.Reason = 'SwitchOff' }
        elseif (-not $actionName -or -not $Actions.ContainsKey($actionName)) { $r.Reason = 'NoAction' }
        else {
            $last = Get-WUOStoreDate -Name "FixLast_$($f.Id)" -StatePath $StatePath
            $count = [int](Get-WUOStoreValue -Name "FixCount_$($f.Id)" -StatePath $StatePath)
            $recent = $last -and (($Now - $last).TotalDays -le 7)
            $actionLast = Get-WUOStoreDate -Name "ActionLast_$actionName" -StatePath $StatePath

            if ($recent -and $count -ge $Config.FixMaxRepeats) {
                $r.Outcome = 'Suppressed'
                $r.Reason = 'RewrittenRepeatedly'
                $r.Detail = "Fixed $count times in 7 days; something else keeps changing it. Not re-applying."
            }
            elseif ($actionName -eq 'ResetStack' -and $actionLast -and (($Now - $actionLast).TotalDays -lt $Config.ResetCooldownDays)) {
                $r.Reason = 'Cooldown'
            }
            else {
                try {
                    $detail = [string](& $Actions[$actionName] $f)
                    if ($detail -like 'SKIP:*') {
                        $r.Reason = 'Precondition'
                        $r.Detail = $detail.Substring(5).Trim()
                    }
                    else {
                        $r.Outcome = 'Fixed'
                        $r.Detail = $detail
                    }
                }
                catch {
                    $r.Outcome = 'Failed'
                    $r.Detail = $_.Exception.Message
                }

                if ($r.Outcome -in 'Fixed', 'Failed') {
                    Set-WUOStoreValue -Name "FixLast_$($f.Id)" -Value $Now -StatePath $StatePath
                    Set-WUOStoreValue -Name "FixCount_$($f.Id)" -Value ($(if ($recent) { $count + 1 } else { 1 })) -StatePath $StatePath
                    Set-WUOStoreValue -Name "ActionLast_$actionName" -Value $Now -StatePath $StatePath
                }
            }
        }
        $results.Add([pscustomobject]$r)
    }
    $results.ToArray()
}
