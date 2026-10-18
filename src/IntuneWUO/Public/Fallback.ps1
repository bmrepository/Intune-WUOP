function Get-WUOOfferedUpdate {
    <#
    .SYNOPSIS
        Lists software updates Windows Update offers this device from the DEFAULT service (read-only).
        Uses the native WUA API so it works with or without PSWindowsUpdate.
    #>
    [CmdletBinding()]
    param()

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 0   # ssDefault: never pick another service
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    foreach ($u in $result.Updates) {
        [pscustomobject]@{
            UpdateId             = $u.Identity.UpdateID
            Title                = $u.Title
            KB                   = (@($u.KBArticleIDs) -join ',')
            Categories           = @($u.Categories | ForEach-Object { $_.Name })
            Type                 = [int]$u.Type
            BrowseOnly           = [bool]$u.BrowseOnly
            LastDeploymentChange = $u.LastDeploymentChangeTime
        }
    }
}

function Select-WUOFallbackCandidate {
    <#
    .SYNOPSIS
        Pure decision: which offered updates is the fallback allowed to install?
        An update qualifies only if it is a quality/security update (not a driver, upgrade, feature pack,
        definition update or optional/browse-only update), has been offered longer than the ring deadline
        plus FallbackGraceDays, and has fewer than FallbackMaxAttempts failed attempts.
        Returns every update with Eligible and Reason, so the log can explain each decision.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Updates = @(),
        [Parameter(Mandatory)]$Config,
        [int]$DeadlineDays = 7,
        [hashtable]$AttemptCounts = @{},
        [hashtable]$FirstSeen = @{},
        [datetime]$Now = (Get-Date)
    )

    $threshold = $DeadlineDays + $Config.FallbackGraceDays
    foreach ($u in $Updates) {
        $cats = @($u.Categories) -join ';'
        $reason = $null
        $age = 0.0

        if ($u.Type -eq 2) { $reason = 'Driver' }
        elseif ($u.BrowseOnly) { $reason = 'OptionalUpdate' }
        elseif ($cats -match 'Drivers|Upgrades|Feature Packs|Definition Updates') { $reason = "ExcludedCategory($cats)" }
        else {
            $ref = $null
            if ($u.LastDeploymentChange -and ([datetime]$u.LastDeploymentChange).Year -gt 2000) { $ref = [datetime]$u.LastDeploymentChange }
            elseif ($FirstSeen.ContainsKey($u.UpdateId)) { $ref = [datetime]$FirstSeen[$u.UpdateId] }
            if ($ref) { $age = [math]::Round(($Now - $ref).TotalDays, 1) }

            if ($AttemptCounts.ContainsKey($u.UpdateId) -and [int]$AttemptCounts[$u.UpdateId] -ge $Config.FallbackMaxAttempts) { $reason = 'MaxAttempts' }
            elseif ($age -lt $threshold) { $reason = 'NotYetOverdue' }
        }

        [pscustomobject]@{
            Update   = $u
            Eligible = ($null -eq $reason)
            Reason   = $(if ($reason) { $reason } else { 'Overdue' })
            AgeDays  = $age
        }
    }
}

function Test-WUOFallbackGuardrail {
    <# Pure: returns the ids of every guardrail that currently blocks an install (empty = clear to proceed). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [bool]$OnBattery = $false,
        [bool]$InstallerBusy = $false
    )

    $blocked = New-Object System.Collections.Generic.List[string]
    $pm = if ($State.PolicyManager) { $State.PolicyManager } else { @{} }

    # Native maintenance windows own install timing; the fallback stays out of the way entirely.
    if ($pm['MaintenanceWindowEnabled'] -eq 1) { $blocked.Add('MAINTENANCE_WINDOW_NATIVE') }
    if ($null -ne $State.DiskFreeGB -and $State.DiskFreeGB -lt $Config.MinFreeDiskGB) { $blocked.Add('DISK_LOW') }
    if ($State.Reboot -and ($State.Reboot['CBS'] -or $State.Reboot['WU'])) { $blocked.Add('RESTART_PENDING') }
    if ($InstallerBusy) { $blocked.Add('INSTALL_BUSY') }
    if ($OnBattery) { $blocked.Add('ON_BATTERY') }
    $blocked.ToArray()
}

function Install-WUOUpdateCom {
    <#
    .SYNOPSIS
        Downloads and installs exactly the given update ids through the native WUA API (default service).
        Never restarts. Returns one result per update: UpdateId, Success, ResultCode, HResult.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$UpdateId)

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 0
    $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($u in $found.Updates) {
        if ($UpdateId -contains $u.Identity.UpdateID) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
            $ids.Add($u.Identity.UpdateID)
        }
    }
    if ($coll.Count -eq 0) { return @() }

    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    [void]$downloader.Download()

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $coll
    $installer.AllowSourcePrompts = $false
    $installer.ForceQuiet = $true
    $res = $installer.Install()

    for ($i = 0; $i -lt $ids.Count; $i++) {
        $one = $res.GetUpdateResult($i)
        [pscustomobject]@{
            UpdateId   = $ids[$i]
            Success    = ($one.ResultCode -in 2, 3)   # 2 = succeeded, 3 = succeeded with errors
            ResultCode = [int]$one.ResultCode
            HResult    = [int]$one.HResult
        }
    }
}

function Get-WUODefaultFallbackBackend {
    <# The real scan/install/battery/busy probes used by the fallback task. #>
    [CmdletBinding()]
    param([string]$ModulePath, [string]$ManifestPath)

    $backendName = Get-WUOBackendName -ModulePath $ModulePath -ManifestPath $ManifestPath
    @{
        Name          = $backendName
        GetOffered    = { @(Get-WUOOfferedUpdate) }
        InstallerBusy = { [bool](Get-Process -Name TiWorker -ErrorAction SilentlyContinue) }
        OnBattery     = {
            $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
            [bool]($b -and @($b | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0)
        }
        Install       = {
            param([string[]]$Ids)
            if ($backendName -eq 'PSWindowsUpdate') {
                $out = @(Invoke-WUOModuleCommand -Cmdlet 'Get-WindowsUpdate' -ModulePath $ModulePath -ManifestPath $ManifestPath `
                    -Parameters @{ Install = $true; AcceptAll = $true; IgnoreReboot = $true; UpdateID = $Ids })
                foreach ($id in $Ids) {
                    $row = $out | Where-Object { $_.PSObject.Properties['UpdateID'] -and $_.UpdateID -eq $id } | Select-Object -First 1
                    $ok = [bool]($row -and "$($row.Result)" -match 'Installed|Downloaded')
                    [pscustomobject]@{ UpdateId = $id; Success = $ok; ResultCode = $(if ($ok) { 2 } else { 4 }); HResult = 0 }
                }
            }
            else { Install-WUOUpdateCom -UpdateId $Ids }
        }.GetNewClosure()
    }
}

function Invoke-WUOFallbackRun {
    <#
    .SYNOPSIS
        One fallback pass. Returns a summary with Outcome:
          Skipped (mode), Blocked (guardrails), NothingEligible, Installed, or PartiallyFailed.
        The backend is injectable so the whole decision path can be tested without touching Windows Update.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][hashtable]$Backend,
        [string]$StatePath = 'HKLM:\SOFTWARE\IntuneWUO\State',
        [datetime]$Now = (Get-Date)
    )

    $summary = [ordered]@{ Outcome = ''; Guardrails = @(); Candidates = @(); Installed = @(); Failed = @() }

    if ($Config.Mode -ne 'RemediateAndFallback') { $summary.Outcome = 'Skipped'; return [pscustomobject]$summary }

    $blocked = @(Test-WUOFallbackGuardrail -State $State -Config $Config `
        -OnBattery ([bool](& $Backend.OnBattery)) -InstallerBusy ([bool](& $Backend.InstallerBusy)))
    if ($blocked.Count -gt 0) { $summary.Outcome = 'Blocked'; $summary.Guardrails = $blocked; return [pscustomobject]$summary }

    $offered = @(& $Backend.GetOffered)
    $attempts = @{}; $firstSeen = @{}
    foreach ($u in $offered) {
        $seen = Get-WUOStoreDate -Name "FirstSeen_$($u.UpdateId)" -StatePath $StatePath
        if (-not $seen) { Set-WUOStoreValue -Name "FirstSeen_$($u.UpdateId)" -Value $Now -StatePath $StatePath; $seen = $Now }
        $firstSeen[$u.UpdateId] = $seen
        $n = Get-WUOStoreValue -Name "Attempts_$($u.UpdateId)" -StatePath $StatePath
        if ($n) { $attempts[$u.UpdateId] = [int]$n }
    }

    $deadline = 7
    $pm = if ($State.PolicyManager) { $State.PolicyManager } else { @{} }
    if ($null -ne $pm['ConfigureDeadlineForQualityUpdates']) { $deadline = [int]$pm['ConfigureDeadlineForQualityUpdates'] }

    $decisions = @(Select-WUOFallbackCandidate -Updates $offered -Config $Config -DeadlineDays $deadline `
        -AttemptCounts $attempts -FirstSeen $firstSeen -Now $Now)
    $summary.Candidates = $decisions
    $eligible = @($decisions | Where-Object Eligible)
    if ($eligible.Count -eq 0) { $summary.Outcome = 'NothingEligible'; return [pscustomobject]$summary }

    $ids = @($eligible | ForEach-Object { $_.Update.UpdateId })
    $results = @(& $Backend.Install $ids)
    foreach ($r in $results) {
        if ($r.Success) {
            $summary.Installed += $r.UpdateId
            Remove-WUOStoreValue -Name "Attempts_$($r.UpdateId)" -StatePath $StatePath
        }
        else {
            $summary.Failed += $r.UpdateId
            $prev = [int](Get-WUOStoreValue -Name "Attempts_$($r.UpdateId)" -StatePath $StatePath)
            Set-WUOStoreValue -Name "Attempts_$($r.UpdateId)" -Value ($prev + 1) -StatePath $StatePath
        }
    }
    $summary.Outcome = $(if (@($summary.Failed).Count -gt 0) { 'PartiallyFailed' } else { 'Installed' })
    [pscustomobject]$summary
}
