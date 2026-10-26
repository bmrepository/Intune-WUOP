$script:WUOEventLog = 'IntuneWUO'
$script:WUOEventSource = 'IntuneWUO'

# Stable ids. Findings are 2000+index, fixes are 3000+index (same index), so a finding and its fix line up.
$script:WUOKnownFindings = @(
    'POLICY_CONFLICT_DONOTCONNECT', 'POLICY_CONFLICT_DISABLEWUACCESS', 'POLICY_CONFLICT_NOAUTOUPDATE',
    'WSUS_REMNANT', 'DUALSCAN_CONFLICT',
    'SVC_DISABLED_wuauserv', 'SVC_DISABLED_UsoSvc', 'SVC_DISABLED_BITS', 'SVC_DISABLED_WaaSMedicSvc',
    'SVC_DISABLED_wlidsvc', 'SVC_DISABLED_DiagTrack',
    'PAUSE_QUALITY_USER', 'PAUSE_FEATURE_USER', 'PAUSE_POLICY',
    'DIAGDATA_LOW', 'SYNC_STALE', 'SCAN_STALE', 'DISK_LOW', 'RESTART_PENDING', 'CONFIGMGR_PRESENT',
    'HOTPATCH_UNSUPPORTED_OS', 'HOTPATCH_VBS_NOT_RUNNING', 'HOTPATCH_CHPE_ENABLED',
    'FALLBACK_TASK_MISSING',
    'AUTOPATCH_READINESS_FAILED', 'AUTOPATCH_READINESS_STALE', 'AUTOPATCH_BROKER_ABSENT',
    'UPDATE_OVERDUE'
)

function Get-WUOEventId {
    <#
    .SYNOPSIS
        Maps an event kind (and finding id) to its fixed event id.
        Kinds: RunComplete=1001, RunOff=1002, Finding=2000+n, Fix=3000+n, FixFailed=3500+n,
        FallbackInstalled=4001, FallbackFailed=4002, FallbackSkipped=4003, FallbackNothing=4004, Error=9000.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('RunComplete', 'RunOff', 'Finding', 'Fix', 'FixFailed', 'FallbackInstalled', 'FallbackFailed', 'FallbackSkipped', 'FallbackNothing', 'Error')][string]$Kind,
        [string]$FindingId
    )
    switch ($Kind) {
        'RunComplete'       { return 1001 }
        'RunOff'            { return 1002 }
        'FallbackInstalled' { return 4001 }
        'FallbackFailed'    { return 4002 }
        'FallbackSkipped'   { return 4003 }
        'FallbackNothing'   { return 4004 }
        'Error'             { return 9000 }
    }
    $idx = [array]::IndexOf($script:WUOKnownFindings, $FindingId)
    if ($idx -lt 0) { $idx = 99 }   # unknown finding ids share a catch-all slot
    switch ($Kind) {
        'Finding'   { return 2000 + $idx }
        'Fix'       { return 3000 + $idx }
        'FixFailed' { return 3500 + $idx }
    }
}

function Write-WUOEvent {
    <# Writes to the IntuneWUO event log if the source exists. Never throws. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information'
    )
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($script:WUOEventSource)) {
            Write-EventLog -LogName $script:WUOEventLog -Source $script:WUOEventSource -EventId $Id -EntryType $EntryType -Message $Message
        }
    }
    catch { }
}

function Register-WUOEventSource {
    <# Creates the IntuneWUO log and source. Needs admin; called by the Win32 install script. #>
    [CmdletBinding()]
    param()
    if (-not [System.Diagnostics.EventLog]::SourceExists($script:WUOEventSource)) {
        New-EventLog -LogName $script:WUOEventLog -Source $script:WUOEventSource
        Limit-EventLog -LogName $script:WUOEventLog -MaximumSize 4MB -OverflowAction OverwriteAsNeeded
    }
}
