# ---------------------------------------------------------------------------------------------------------
# Settings. Edit them here before uploading, and keep the same values in the detection and remediation
# scripts. 1 = on, 0 = off. Whether anything is fixed at all is decided in Intune: a package with only the
# detection script reports; add the remediation script to the package and fixes run automatically.
# ---------------------------------------------------------------------------------------------------------
$WUOSettings = @{
    FixServices           = 1    # re-enable disabled update services (wuauserv, UsoSvc, BITS, WaaSMedicSvc, wlidsvc, DiagTrack)
    FixPauses             = 1    # clear update pauses set by a user (a pause set by policy is never touched)
    FixSyncAndCleanup     = 1    # start an Intune sync when the last one is stale; clean up when disk space is low
    InstallOverdueUpdates = 1    # install approved quality updates that are overdue (never drivers or feature updates; never restarts)
    FixResetStack         = 0    # reset the update stack when scans keep failing (side effect: wipes the Windows Update history list)
    FallbackGraceDays     = 3    # days after the ring deadline before an offered update counts as overdue
    FallbackMaxAttempts   = 3    # failed install attempts per update before giving up on it
    MinFreeDiskGB         = 20   # below this, report DISK_LOW and do not install
    ResetCooldownDays     = 7    # minimum days between update-stack resets
    SyncStaleHours        = 24   # hours without an Intune sync before SYNC_STALE
    ScanStaleDays         = 7    # days without a successful Windows Update scan before SCAN_STALE
    FixMaxRepeats         = 3    # a fix needed this many times in 7 days is suppressed (something else keeps undoing it)
}
