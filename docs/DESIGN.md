# Intune-WUO design

Status: v0.2, implemented and unit-tested; not yet validated end to end on a device. The requirements behind this design (R1-R15) are summarised in the README; this document records how they are met.

## 1. Principles

1. **Autopatch decides, Intune-WUO enables.** Which updates are approved, and when, belongs to Windows Autopatch and the update ring. The tool fixes the device so that decision can take effect, and only as a last resort installs what Windows Update already offers.
2. **Safe by default.** Missing or invalid configuration means `ReportOnly`. `Off` is a kill switch. Every fix has its own switch.
3. **Never surprise the user.** No restarts, no UI, no policy writes, no service-manager changes, no content selection.
4. **Pure decisions, thin I/O.** State collection is separate from evaluation (`Get-WUOState` vs `Get-WUOFinding`), and every side effect sits behind an injectable action, so logic is tested without touching Windows.

## 2. Components

| Component | File(s) | Runs as | Notes |
|---|---|---|---|
| Engine module | `src/IntuneWUO/` | - | Everything below is a function in this module |
| Detect | `src/Remediation/Detect-WUO.ps1` | SYSTEM, 64-bit, Remediation | Read-only. Exit 1 only when a finding is fixable under the current mode and switches. Any internal error exits 0 so a bug can never trigger remediation |
| Remediate | `src/Remediation/Remediate-WUO.ps1` | SYSTEM, 64-bit, Remediation | Re-collects state, applies fixes under the shared lock |
| Fallback task | `src/Win32/Invoke-WUOFallback.ps1` | SYSTEM, scheduled task | Installs overdue approved updates |
| Install / Uninstall / Detect app | `src/Win32/` | SYSTEM, Win32 app | Copies files, ACLs the folder, creates the event log, registers the task |
| Config packages | `src/Config/` templates, stamped by the build | SYSTEM, Remediation | One per mode; writes `HKLM\SOFTWARE\IntuneWUO` |
| Build | `build/Build-IntuneWUO.ps1` | developer | Staging, PSWindowsUpdate pinning and hashing, signing, `.intunewin` |

Device layout: `%ProgramFiles%\IntuneWUO\{Module\, ThirdParty\, Invoke-WUOFallback.ps1, version.txt}`. Standard users get read/execute only.

## 3. Configuration (`HKLM\SOFTWARE\IntuneWUO`)

Validated by `ConvertTo-WUOConfig`. An invalid value is ignored (default used) and logged as a warning; an invalid `Mode` becomes `ReportOnly`.

| Value | Default | Range | Meaning |
|---|---|---|---|
| `Mode` | `ReportOnly` | Off, ReportOnly, Remediate, RemediateAndFallback | See the README |
| `FallbackGraceDays` | 3 | 0-30 | Added to the ring's quality deadline before the fallback acts |
| `FallbackMaxAttempts` | 3 | 1-10 | Failed installs per update before giving up |
| `MinFreeDiskGB` | 20 | 1-500 | Disk finding and fallback guardrail |
| `ResetCooldownDays` | 7 | 1-90 | Minimum gap between update-stack resets |
| `SyncStaleHours` | 24 | 1-720 | MDM sync age that raises `SYNC_STALE` |
| `ScanStaleDays` | 7 | 1-90 | Scan age that raises `SCAN_STALE` |
| `FixMaxRepeats` | 3 | 1-10 | Repeats within 7 days before a fix is suppressed |
| `FixServices`, `FixPauses`, `FixPolicyKeys`, `FixSyncAndCleanup` | 1 | 0/1 | Per-category fix switches |

`HKLM\SOFTWARE\IntuneWUO\State` is tool-owned: `FixLast_<id>`, `FixCount_<id>`, `ActionLast_<action>`, `FirstSeen_<updateId>`, `Attempts_<updateId>`.

## 4. Finding catalogue

Severity: Critical, Warning, Info. "Auto-fix" names the `Fix*` switch category; `-` means report-only.

| Id | Severity | Auto-fix | Condition |
|---|---|---|---|
| `POLICY_CONFLICT_DONOTCONNECT` | Critical | - | `DoNotConnectToWindowsUpdateInternetLocations` present under the WindowsUpdate policy key |
| `POLICY_CONFLICT_DISABLEWUACCESS` | Critical | - | `DisableWindowsUpdateAccess` present |
| `POLICY_CONFLICT_NOAUTOUPDATE` | Critical | - | `AU\NoAutoUpdate` present |
| `WSUS_REMNANT` | Warning | - | `UseWUServer`, `WUServer` or `UpdateServiceUrl` configured |
| `DUALSCAN_CONFLICT` | Critical | - | WSUS configured and `DisableDualScan` on |
| `SVC_DISABLED_<name>` | Critical (wuauserv, UsoSvc, wlidsvc) / Warning | Services | Start type is *Disabled* (a stopped trigger-start service is healthy and not flagged) |
| `PAUSE_QUALITY_USER`, `PAUSE_FEATURE_USER` | Warning | Pauses | Paused but no policy pause is set |
| `PAUSE_POLICY` | Info | - | Paused by Intune policy; never changed |
| `DIAGDATA_LOW` | Warning | - | Diagnostic data below Required |
| `SYNC_STALE` | Warning | SyncAndCleanup | Last MDM sync older than `SyncStaleHours` |
| `SCAN_STALE` | Warning | Services | No successful scan within `ScanStaleDays` (fix = update-stack reset, rate-limited) |
| `DISK_LOW` | Warning | SyncAndCleanup | Free space below `MinFreeDiskGB` |
| `RESTART_PENDING` | Info | - | CBS or Windows Update restart flag set |
| `CONFIGMGR_PRESENT` | Info | - | ConfigMgr client present |
| `AUTOPATCH_READINESS_FAILED` | Warning | - | The Autopatch Client Broker's latest `RunDeviceReadinessChecks` has a non-zero `ResultsBitmask` or any `ErrorCodes` |
| `AUTOPATCH_READINESS_STALE` | Warning | - | Broker readiness timestamp older than 7 days |
| `AUTOPATCH_BROKER_ABSENT` | Info | - | No `HKLM\SOFTWARE\Microsoft\WindowsAutopatch\ClientBroker` key |
| `FALLBACK_TASK_MISSING` | Warning | Services | Mode is `RemediateAndFallback` and the task is missing or disabled (fix = re-register) |
| `HOTPATCH_UNSUPPORTED_OS`, `HOTPATCH_VBS_NOT_RUNNING`, `HOTPATCH_CHPE_ENABLED` | Warning | - | Only when hotpatch enrollment is known (see limitations) |

`PendingFileRenameOperations` is deliberately not treated as a pending restart: it is set on many healthy devices.

## 5. Fix actions and guardrails

| Action | Does | Does not |
|---|---|---|
| `RepairService` | Sets the service to its default start type; starts it if default is Automatic | Touch services it has no default for |
| `ClearPause` | Removes the user-pause values under `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` | Touch policy pauses or the system-owned status values |
| `TriggerSync` | Starts the enrollment's `PushLaunch` task | - |
| `CleanupDisk` | Deletes temp files older than 7 days; runs DISM `/StartComponentCleanup` (20-minute cap) | - |
| `ResetStack` | Stops wuauserv, bits, cryptsvc; renames SoftwareDistribution and catroot2 to `.bak-<stamp>`; restarts the services; then prunes older `.bak-<stamp>` backups (keeps the newest, exact-name match only). **Side effect: the Windows Update history list is reset** (installed updates stay installed) | Run during an install (TiWorker) or with a restart pending (skipped) |
| `RegisterTask` | Re-registers the fallback task | - |

Guardrails applied by `Invoke-WUORemediation` for every fix:
- Only findings marked auto-fixable, only in `Remediate`/`RemediateAndFallback`, only if the category switch is on.
- **Repeat suppression:** if a fix has been applied `FixMaxRepeats` times within 7 days, it is `Suppressed` and reported instead of re-applied.
- **Cooldown** for `ResetStack`.
- An action returning `SKIP: <reason>` is a precondition skip and is not counted as an attempt.
- A failure is recorded and returned; it never throws.

## 6. Fallback installer

Runs from the scheduled task (daily 10:00 + up to 6 h random delay, at startup + 15 min, catch-up after a missed run; SYSTEM; network and AC power required; one instance; 4 h limit). One pass:

1. Skip unless `Mode = RemediateAndFallback`.
2. Take the `Global\IntuneWUO` mutex (shared with Remediate); exit if busy.
3. **Guardrails** (any blocks the pass): native maintenance window enabled (the fallback stays out of the way entirely), low disk, restart pending, installer busy (TiWorker), on battery.
4. Scan the **default** update service for software updates (`ServerSelection = ssDefault`).
5. **Eligibility** per update: not a driver, not browse-only/optional, not in Upgrades / Feature Packs / Drivers / Definition Updates; offered longer than *ring quality deadline + `FallbackGraceDays`* (age from the update's deployment date, falling back to first-seen); fewer than `FallbackMaxAttempts` failures.
6. Install exactly the eligible ids. No restart is ever requested.
7. Record per-update success or failure counters; log and write events.

**Hotpatch:** nothing special is needed. The fallback installs whatever Windows Update offers: the hotpatch package in a hotpatch month, the LCU in a baseline month. The baseline/hotpatch calendar is never hard-coded.

## 7. Update backend

`Get-WUOBackendName` picks **PSWindowsUpdate** only if the pinned copy is present, verifies against `manifest.json` (every file's SHA-256, no extra or missing files) and the session is FullLanguage. Otherwise it uses **native WUA COM**. All PSWindowsUpdate calls go through `Invoke-WUOModuleCommand`, which first runs `Test-WUOModuleCall`:

- Allowed: `Get-WindowsUpdate` (parameters Install, AcceptAll, IgnoreReboot, UpdateID, Download), `Get-WUHistory`, `Get-WULastResults`, `Get-WURebootStatus`, `Get-WUInstallerStatus`, `Reset-WUComponents`.
- An install or download without explicit `-UpdateID` values is refused.
- Blocked outright: `Set-WUSettings`, `Set-PSWUSettings`, `Add-/Remove-WUServiceManager`, `Enable-WURemoting`, `Invoke-WUJob`, `Update-WUModule`, `Remove-WindowsUpdate`, `Get-WUOfflineMSU`.
- `-MicrosoftUpdate`, `-KBArticleID`, `-ServiceID`, `-AutoReboot`, `-ScheduleReboot` and anything else not listed are refused.

## 8. Reporting

- **Remediation output**, one line, at most 2,048 characters: `WUO|v1|<Compliant|NonCompliant|Disabled>|Mode=<mode>|Build=<n>|F=<ids, most severe first>[+N]`. After a remediation: `WUO|v1|Remediated|Fixed=...|Failed=...|Suppressed=...`.
- **Logs:** `IntuneWUO.jsonl` and `IntuneWUO.log` (CMTrace) in the IME logs folder `IntuneWUO\`, rotated at 5 MB. Falls back to `%TEMP%\IntuneWUO` when the folder is not writable. Logging never throws.
- **Event log `IntuneWUO`:** `1001` run complete, `1002` Off, `2000+n` finding n, `3000+n` fix n applied, `3500+n` fix n failed, `4001` installed, `4002` failed, `4003` skipped, `4004` nothing overdue, `9000` error. `n` is the finding's position in the known-findings list in `Events.ps1` (unknown = 99); new findings are appended so ids stay stable.

## 9. Security model

Least privilege on the install folder; script signing supported by the build; PSWindowsUpdate pinned and hash-verified, never downloaded at runtime; constrained-language sessions fall back to native COM; no secrets stored; no outbound data; every change logged with its outcome.

## 10. Test plan

Pester suites in `tests/`: configuration validation, every finding (including "healthy device has none", "stopped trigger-start service is not a fault", "policy pause is not a fault"), the remediation guardrails (mode, switches, report-only untouched, repeat suppression, cooldown, SKIP handling), fallback eligibility and guardrails, the full fallback run with a fake backend (including "installs only the overdue eligible update" and "gives up after max attempts"), the PSWindowsUpdate allow-list, integrity checking and backend choice, the scheduled-task definition, event ids and the build output.

Not unit-testable and therefore a manual validation step on a **disposable test device**: real service repair, pause clearing, sync trigger, DISM cleanup, update-stack reset, task registration under SYSTEM, a real install, and the real PSWindowsUpdate module.

## 11. Known limitations

- Policy values are not yet attributed to domain GPO vs local policy, so the three Autopatch conflict values and WSUS remnants are report-only and `FixPolicyKeys` currently has no fix to run.
- Hotpatch enrollment is not read yet; hotpatch findings are skipped until it is.
- Autopatch readiness comes from the Client Broker's registry key and `ClientBroker.log` (observed on broker 1.2509.201.3, not a documented contract). The documented `DRCResults.json.log` path belongs to an older agent and is not read. The broker's `ActionsFeedUri` value carries a signed access token and is deliberately never read.
- The maintenance-window guardrail is conservative: any enabled native window disables the fallback rather than computing the window.
- `WaaSMedicSvc` is protected by Windows; repairing its start type is expected to fail and will be reported as such.
- PSWindowsUpdate result mapping is based on its documented output and is untested against the real module.
- **On-device validation (2026-10-18):** the first real run found two bugs that mock-based tests could not: the fallback script defaulted its install folder from `` in a param block (empty under `-File` on Windows PowerShell 5.1, and the scheduled task passes no arguments), and the task-status state was an object indexed like a hashtable. Both are fixed; Pester now scans every script for `` in param defaults and runs the built fallback with no arguments.
