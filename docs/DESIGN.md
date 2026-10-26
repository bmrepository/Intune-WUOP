# Intune-WUO design

Status: v1.0. The engine is implemented and unit-tested, its fixes were validated end to end on a Windows 11 test device, and the standalone detection script has reported correctly through Intune on two Windows 11 test devices. The recommended delivery is now a **standalone Intune Remediations package** (two self-contained scripts); the earlier Win32 app edition remains in the repository as an option. The requirements behind this design (R1-R15) are summarised in the README; this document records how they are met.

## 1. Principles

1. **Autopatch decides, Intune-WUO enables.** Which updates are approved, and when, belongs to Windows Autopatch and the update ring. The tool fixes the device so that decision can take effect, and installs only what Windows Update already offers once it is overdue.
2. **Intune is the switch.** A package with only the detection script reports; adding the remediation script turns fixes on; unassigning it stops everything. No device-side mode setting is needed. Every fix also has its own setting.
3. **Never surprise the user.** No restarts, no UI, no policy writes, no service-manager changes, no content selection.
4. **Pure decisions, thin I/O.** State collection is separate from evaluation (`Get-WUOState` vs `Get-WUOFinding`), and every side effect sits behind an injectable action, so logic is tested without touching Windows.

## 2. Components

### Standalone package (recommended)

| Component | File(s) | Runs as | Notes |
|---|---|---|---|
| Engine module | `src/IntuneWUO/` | - | Everything below is a function in this module |
| Detection script | `remediation/Detect-IntuneWUO.ps1` | SYSTEM, 64-bit, Remediations | Generated. Exit 1 on any Warning or Critical finding, so a detection-only package reports *With issues*. Any internal error exits 0 so a bug can never trigger remediation |
| Remediation script | `remediation/Remediate-IntuneWUO.ps1` | SYSTEM, 64-bit, Remediations | Generated. Re-collects state and applies fixes under the shared lock, including the overdue-update install |
| Templates and settings | `src/Standalone/` | - | `Detect.template.ps1`, `Remediate.template.ps1`, `Settings.ps1` |
| Build | `build/Build-RemediationScripts.ps1` | developer | Embeds every `src/IntuneWUO/Public/*.ps1` (in the module's load order) inside `New-Module { ... }` so the code runs with the same scoping and strict mode as the tested module, inserts the settings block, and checks ASCII-only, no BOM and that the result parses |

Both scripts call `ConvertTo-WUOConfig` with the settings block plus `Mode = 'Remediate'`. Inside the engine, `Remediate` simply means "fixes are allowed when this code runs"; whether the remediation script runs at all is decided by the Intune package. The status line shows `Mode=Script`.

### Win32 app edition (optional)

| Component | File(s) | Runs as | Notes |
|---|---|---|---|
| Detect / Remediate | `src/Remediation/Detect-WUO.ps1`, `Remediate-WUO.ps1` | SYSTEM, 64-bit, Remediations | Import the module installed by the app. Detect exits 1 only when a finding is fixable under the registry mode and switches |
| Fallback task | `src/Win32/Invoke-WUOFallback.ps1` | SYSTEM, scheduled task | Installs overdue approved updates (daily 10:00 + up to 6 h random delay, at startup + 15 min, catch-up; AC power and network; 4 h limit) |
| Install / Uninstall / Detect app | `src/Win32/` | SYSTEM, Win32 app | Copies files to `%ProgramFiles%\IntuneWUO`, ACLs the folder, creates the event log, registers the task |
| Config packages | `src/Config/` templates | SYSTEM, Remediations | One per mode; writes `HKLM\SOFTWARE\IntuneWUO` |
| Build | `build/Build-IntuneWUO.ps1` | developer | Staging, optional PSWindowsUpdate pinning and hashing, signing, `.intunewin` |

## 3. Configuration

Validated by `ConvertTo-WUOConfig`. An invalid value is ignored (default used) and logged as a warning; an invalid `Mode` becomes `ReportOnly`. The standalone scripts take these values from their settings block; the Win32 edition reads them from `HKLM\SOFTWARE\IntuneWUO`.

| Value | Default (registry) | Default (standalone) | Range | Meaning |
|---|---|---|---|---|
| `Mode` | `ReportOnly` | `Remediate` (fixed) | Off, ReportOnly, Remediate, RemediateAndFallback | Win32 edition only; see the README |
| `FallbackGraceDays` | 3 | 3 | 0-30 | Added to the ring's quality deadline before an offered update is overdue |
| `FallbackMaxAttempts` | 3 | 3 | 1-10 | Failed installs per update before giving up |
| `MinFreeDiskGB` | 20 | 20 | 1-500 | Disk finding and install guardrail |
| `ResetCooldownDays` | 7 | 7 | 1-90 | Minimum gap between update-stack resets |
| `SyncStaleHours` | 24 | 24 | 1-720 | MDM sync age that raises `SYNC_STALE` |
| `ScanStaleDays` | 7 | 7 | 1-90 | Scan age that raises `SCAN_STALE` |
| `FixMaxRepeats` | 3 | 3 | 1-10 | Repeats within 7 days before a fix is suppressed |
| `FixServices`, `FixPauses`, `FixSyncAndCleanup` | 1 | 1 | 0/1 | Per-category fix switches |
| `FixPolicyKeys` | 1 | - | 0/1 | No fix uses it yet (see limitations) |
| `FixResetStack` | 0 | 0 | 0/1 | Allows the update-stack reset (it wipes the Windows Update history list) |
| `InstallOverdueUpdates` | 0 | 1 | 0/1 | Lets `Remediate` install overdue updates. `RemediateAndFallback` always may; `ReportOnly` and `Off` never do |

`HKLM\SOFTWARE\IntuneWUO\State` is tool-owned: `FixLast_<id>`, `FixCount_<id>`, `ActionLast_<action>`, `FirstSeen_<updateId>`, `Attempts_<updateId>`. Detection writes `FirstSeen_*` only.

## 4. Finding catalogue

Severity: Critical, Warning, Info. "Auto-fix" names the fix category (and so the setting that allows it); `-` means report-only. [findings.json](findings.json) is the machine-readable copy, kept in sync by a Pester test.

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
| `SCAN_STALE` | Warning | ResetStack | No successful scan within `ScanStaleDays` (fix = update-stack reset, rate-limited, off by default) |
| `DISK_LOW` | Warning | SyncAndCleanup | Free space below `MinFreeDiskGB` |
| `RESTART_PENDING` | Info | - | CBS or Windows Update restart flag set |
| `CONFIGMGR_PRESENT` | Info | - | ConfigMgr client present |
| `AUTOPATCH_READINESS_FAILED` | Warning | - | The Autopatch Client Broker's latest `RunDeviceReadinessChecks` has a non-zero `ResultsBitmask` or any `ErrorCodes` |
| `AUTOPATCH_READINESS_STALE` | Warning | - | Broker readiness timestamp older than 7 days |
| `AUTOPATCH_BROKER_ABSENT` | Info | - | No `HKLM\SOFTWARE\Microsoft\WindowsAutopatch\ClientBroker` key |
| `FALLBACK_TASK_MISSING` | Warning | Services | Win32 edition, Mode `RemediateAndFallback`, task missing or disabled (fix = re-register) |
| `HOTPATCH_UNSUPPORTED_OS`, `HOTPATCH_VBS_NOT_RUNNING`, `HOTPATCH_CHPE_ENABLED` | Warning | - | Only when hotpatch enrollment is known (see limitations) |
| `UPDATE_OVERDUE` | Warning | Updates | An offered update passes the eligibility rules in section 6. Evaluated only when the offered updates were collected (`Get-WUOState -IncludeOfferedUpdates`) |

`PendingFileRenameOperations` is deliberately not treated as a pending restart: it is set on many healthy devices.

## 5. Fix actions and guardrails

| Action | Does | Does not |
|---|---|---|
| `RepairService` | Sets the service to its default start type; starts it if default is Automatic | Touch services it has no default for |
| `ClearPause` | Removes the user-pause values under `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` | Touch policy pauses or the system-owned status values |
| `TriggerSync` | Starts the enrollment's `PushLaunch` task | - |
| `CleanupDisk` | Deletes temp files older than 7 days; runs DISM `/StartComponentCleanup` (20-minute cap) | - |
| `ResetStack` | Stops wuauserv, bits, cryptsvc; renames SoftwareDistribution and catroot2 to `.bak-<stamp>`; restarts the services; then prunes older `.bak-<stamp>` backups (keeps the newest, exact-name match only). **Side effect: the Windows Update history list is reset** (installed updates stay installed) | Run during an install (TiWorker) or with a restart pending (skipped) |
| `InstallUpdates` | Runs the update installer (section 6) on the scan the remediation just made | Restart, or install anything section 6 does not allow |
| `RegisterTask` | Re-registers the fallback task (Win32 edition) | - |

Guardrails applied by `Invoke-WUORemediation` for every fix:
- Only findings marked auto-fixable, only in `Remediate`/`RemediateAndFallback`, only if the category setting is on.
- **Repeat suppression:** if a fix has been applied `FixMaxRepeats` times within 7 days, it is `Suppressed` and reported instead of re-applied.
- **Cooldown** for `ResetStack`.
- An action returning `SKIP: <reason>` is a precondition skip and is not counted as an attempt.
- A failure is recorded and returned; it never throws.

## 6. Update installer

Used by the standalone remediation script (`InstallUpdates` action) and by the Win32 edition's fallback task. One pass (`Invoke-WUOFallbackRun`):

1. Allowed only when `Mode = RemediateAndFallback`, or `Mode = Remediate` with `InstallOverdueUpdates` on.
2. The caller holds the `Global\IntuneWUO` mutex.
3. **Guardrails** (any blocks the pass): native maintenance window enabled (the tool stays out of the way entirely), low disk, restart pending, installer busy (TiWorker), on battery.
4. Scan the **default** update service for software updates (`ServerSelection = ssDefault`). The standalone remediation reuses the scan it made when collecting state.
5. **Eligibility** per update: not a driver, not browse-only/optional, not in Upgrades / Feature Packs / Drivers / Definition Updates; offered longer than *ring quality deadline (`ConfigureDeadlineForQualityUpdates`, default 7) + `FallbackGraceDays`* (age from the update's deployment date plus the ring's `DeferQualityUpdatesPeriodInDays`, so a ring that defers is not flagged before it could have been offered; falling back to first-seen); fewer than `FallbackMaxAttempts` failures.
6. Install exactly the eligible ids through native WUA COM (or the pinned PSWindowsUpdate in the Win32 edition). No restart is ever requested.
7. Record per-update success or failure counters; log each decision and write events.

**Hotpatch:** nothing special is needed. The installer takes whatever Windows Update offers: the hotpatch package in a hotpatch month, the LCU in a baseline month. The baseline/hotpatch calendar is never hard-coded.

**Run time:** Microsoft does not document a time limit for Remediations scripts (the 30-minute limit applies to platform scripts). A long install that is cut off is picked up by the next run, because the attempt counter only counts recorded failures.

## 7. Update backend

The standalone scripts always use **native WUA COM**. In the Win32 edition, `Get-WUOBackendName` picks **PSWindowsUpdate** only if the pinned copy is present, verifies against `manifest.json` (every file's SHA-256, no extra or missing files) and the session is FullLanguage. All PSWindowsUpdate calls go through `Invoke-WUOModuleCommand`, which first runs `Test-WUOModuleCall`:

- Allowed: `Get-WindowsUpdate` (parameters Install, AcceptAll, IgnoreReboot, UpdateID, Download), `Get-WUHistory`, `Get-WULastResults`, `Get-WURebootStatus`, `Get-WUInstallerStatus`, `Reset-WUComponents`.
- An install or download without explicit `-UpdateID` values is refused.
- Blocked outright: `Set-WUSettings`, `Set-PSWUSettings`, `Add-/Remove-WUServiceManager`, `Enable-WURemoting`, `Invoke-WUJob`, `Update-WUModule`, `Remove-WindowsUpdate`, `Get-WUOfflineMSU`.
- `-MicrosoftUpdate`, `-KBArticleID`, `-ServiceID`, `-AutoReboot`, `-ScheduleReboot` and anything else not listed are refused.

## 8. Reporting

- **Detection output**, one line, at most 2,048 characters: `WUO|v1|<Compliant|NonCompliant|Disabled>|Mode=<Script or mode>|Build=<n>[|Ring=<ring>]|F=<ids, most severe first>[+N]`. `NonCompliant` means at least one Warning or Critical finding. A script failure prints `WUO|v1|Error|<message>`.
- **Remediation output:** `WUO|v1|Remediated|Fixed=...|Failed=...|Suppressed=...|AdminAction=<report-only Warning/Critical ids>` (the Win32 edition omits `AdminAction`).
- **Logs:** `IntuneWUO.jsonl` and `IntuneWUO.log` (CMTrace) in the IME logs folder `IntuneWUO\`, rotated at 5 MB. Falls back to `%TEMP%\IntuneWUO` when the folder is not writable. Logging never throws.
- **Event log `IntuneWUO`** (created by the first SYSTEM run in the standalone package, by the app installer in the Win32 edition): `1001` run complete, `1002` Off, `2000+n` finding n, `3000+n` fix n applied, `3500+n` fix n failed, `4001` installed, `4002` failed, `4003` skipped or blocked, `4004` nothing overdue, `9000` error. `n` is the finding's position in the known-findings list in `Events.ps1` (unknown = 99); new findings are appended so ids stay stable.

## 9. Security model

Self-contained scripts with nothing downloaded at runtime; script signing possible; no secrets stored; no outbound data; every change logged with its outcome. The Win32 edition adds least privilege on the install folder and a pinned, hash-verified PSWindowsUpdate; constrained-language sessions fall back to native COM.

## 10. Test plan

Pester suites in `tests/`: configuration validation, every finding (including "healthy device has none", "stopped trigger-start service is not a fault", "policy pause is not a fault"), the remediation guardrails (mode, switches, report-only untouched, repeat suppression, cooldown, SKIP handling), update-installer eligibility and guardrails, the full installer run with a fake backend (including "installs only the overdue eligible update", "gives up after max attempts" and "ReportOnly never installs"), `UPDATE_OVERDUE` (deadline from PolicyManager, drivers and feature updates ignored), the standalone scripts (regenerated output equals the committed files, ASCII without BOM, parse, no install dependency, safe defaults), the PSWindowsUpdate allow-list, integrity checking and backend choice, the scheduled-task definition, event ids and the Win32 build output.

Not unit-testable and therefore validated on a **test device** or in a **test tenant**: real service repair, pause clearing, sync trigger, DISM cleanup, update-stack reset, a real install, the package running as SYSTEM through Intune, and the real PSWindowsUpdate module.

## 11. Known limitations

- Policy values are not yet attributed to domain GPO vs local policy, so the three Autopatch conflict values and WSUS remnants are report-only and `FixPolicyKeys` currently has no fix to run.
- Hotpatch enrollment is not read yet; hotpatch findings are skipped until it is.
- Autopatch readiness comes from the Client Broker's registry key and `ClientBroker.log` (observed on broker 1.2509.201.3, not a documented contract). The documented `DRCResults.json.log` path belongs to an older agent and is not read. The broker's `ActionsFeedUri` value carries a signed access token and is deliberately never read.
- The maintenance-window guardrail is conservative: any enabled native window disables installs rather than computing the window.
- `WaaSMedicSvc` is protected by Windows; repairing its start type is expected to fail and will be reported as such.
- Detection exits 1 for report-only findings too (for example a WSUS remnant), so once the remediation script is in the package Intune runs it on those devices every time; it fixes nothing there and reports the ids under `AdminAction`.
- The standalone scripts load the engine with `New-Module`, which needs Full Language mode. Under an enforced App Control policy that puts scripts in Constrained Language mode, sign the scripts with a trusted signer.
- PSWindowsUpdate result mapping (Win32 edition) is based on its documented output and is untested against the real module.
- **On-device validation:** the first real run found two bugs that mock-based tests could not: the fallback script defaulted its install folder from `$PSScriptRoot` in a param block (empty under `-File` on Windows PowerShell 5.1, and the scheduled task passes no arguments), and the task-status state was an object indexed like a hashtable. Both are fixed; Pester now scans every script for `$PSScriptRoot` in param defaults and runs the built fallback with no arguments.
