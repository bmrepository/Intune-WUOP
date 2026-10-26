---
name: intune-wuo-deploy
description: Plan, deploy and operate Intune-WUO, the open-source Windows Update orchestration layer for Intune-managed Windows devices that use Windows Autopatch. Use when the user wants to deploy, roll out, pilot, switch modes, validate or troubleshoot Intune-WUO / IntuneWUO / "WUO", or asks how to detect and fix Windows Update problems that block Autopatch-approved updates, or pastes a status line starting with WUO|v1|.
when_to_use: Examples - "deploy the Intune Windows Update orchestration project to my tenant", "move my Test ring to Remediate", "why is this device NonCompliant WUO|v1|...", "set up Intune Remediations for Autopatch blockers", "roll back Intune-WUO", "what does this finding mean".
---

# Deploy and operate Intune-WUO

Intune-WUO (https://github.com/bmrepository/Intune-WUOP) detects the device-side problems that stop Windows Autopatch-approved updates installing, fixes the safe ones, and as a last resort installs overdue **approved** quality updates. It never restarts a device, shows UI, changes update or Autopatch policy, installs drivers or feature updates, or changes VBS/CHPE.

**Recommended deployment: the standalone Remediations package.** One script package, `Intune-WUO`, built from `remediation/Detect-IntuneWUO.ps1` and `remediation/Remediate-IntuneWUO.ps1`. Nothing else is installed on devices. Intune is the switch:
- detection script only = report only (the equivalent of `ReportOnly`)
- detection + remediation script = fixes on, including installing overdue approved quality updates
- unassign the package = off

Settings are a block at the top of each script (keep both the same). Each device gets exactly one Intune-WUO package. `runRemediationScript` is set **per assignment**, so within one package each group can be report-only or fixing. The optional **Win32 app edition** (modes `Off`, `ReportOnly`, `Remediate`, `RemediateAndFallback` set through one `IntuneWUO-Config-<Mode>` package per device) is only for tenants that already use it.

## 1. Get the knowledge

**Preferred: the MCP server** (offline, read-only, holds no credentials). If a server named `intune-wuo` is connected, use its tools. If it is not, tell the user how to add it:

```
claude mcp add intune-wuo -- npx -y github:bmrepository/Intune-WUOP
```

(other clients: see docs/AI-AGENTS.md in the repository). **Without MCP**, read, in this order: `AGENTS.md`, `docs/AI-AGENTS.md`, README sections *Modes and switches*, *Prerequisites*, *Deployment guide*, and `docs/findings.json` from https://raw.githubusercontent.com/bmrepository/Intune-WUOP/main/ . Do not invent steps, setting names or Graph bodies; take them from those files.

| Need | MCP tool |
|---|---|
| Orientation | `wuo_overview` |
| Are we ready? | `wuo_check_prerequisites` |
| Ordered plan | `wuo_plan_deployment` |
| Graph requests for the package (create, enable-fixes, add-groups, disable-fixes, update-scripts, remove) | `wuo_package_requests` |
| Verify a phase (`detect`, `fix`, `autopatch`) | `wuo_validation_checklist` |
| Explain a device status line | `wuo_interpret_status`, `wuo_explain_finding`, `wuo_list_findings` |
| Any document | `wuo_get_doc` |
| Win32 edition only | `wuo_generate_graph_requests`, `wuo_generate_mode_change`, `wuo_win32_app_reference` |

## 2. Workflow

1. **Orient and ask little.** Call `wuo_overview`. Ask the user only for facts you need (licence, Autopatch registration, group names/ids, co-management, app control, what tenant access you have), then call `wuo_check_prerequisites`. Stop and explain if there are blockers (the usual one: Remediations need Windows Enterprise E3/E5 or equivalent; Microsoft 365 Business Premium is not enough).
2. **Plan.** Call `wuo_plan_deployment` and show the user the phases. Do not skip phases.
3. **Get the scripts.** Nothing to build: the two files in `remediation/` are ready. If the user wants other settings, pass them as `settings` to `wuo_package_requests`, which changes both scripts the same way.
4. **Deploy phase by phase** with `wuo_package_requests`: `create` (detection only, pilot), then `enable-fixes` for the pilot, then `add-groups` / `enable-fixes` ring by ring. **Show each write to the human and wait for an explicit yes** before sending it with your own tool.
5. **Verify** each phase with `wuo_validation_checklist` (`detect`, then `fix`) and the Intune device status. Check that `remediationState` stops being `skipped` once fixes are on.
6. **Promote** one stage at a time: pilot detection only, pilot fixes (2 patch cycles), then each Autopatch ring detection only, then fixes. Never skip a stage. Move the schedule from 1 hour to 8 hours after the pilot.

## 3. Hard rules

- **Start with the pilot group, detection only (the equivalent of `ReportOnly`).** Never assign to All devices or All users for a first rollout.
- **Nothing is sent to a tenant without the human approving that exact batch.** If you have no tenant tool, hand the human the requests or the admin-center steps.
- **Read before you write.** Verify group ids; look for an existing `Intune-WUO` package (or `IntuneWUO-*` objects) to avoid duplicates.
- **Graph's `assign` action replaces the whole assignment list.** Read current assignments first (`wuo_package_requests` does this in two calls: it returns the read request, then the new list once you pass what you read).
- **Never read, print, copy or log the Autopatch `ActionsFeedUri` registry value.** It contains a signed access token. Read the `ClientBroker` key with an explicit property list (`Ring`, `DeviceReadinessTimestamp`).
- Never paste tokens, client secrets or certificates into chat, files or logs.
- Do not change update policy, Autopatch policy, VBS or CHPE yourself. Intune-WUO reports those and leaves them to Intune policy.
- Stop on the first unexpected error. Do not retry writes blindly. Record the id of every object you create and report them to the user.
- Remediation scripts must run as SYSTEM, 64-bit. The Graph bodies already set `runAsAccount: system` and `runAs32Bit: false`.

## 4. Tenant access: what you can do at each level

| Your access | What to do |
|---|---|
| None | Produce the plan and exact requests; the human performs them in the Intune admin center (*Devices > Scripts and remediations*, *Apps*). |
| Read-only | Verify groups, existing packages, assignments and device status; the human does the writes. |
| Write (Graph tool or PowerShell) | Execute the requests after approval, pilot first. In a terminal, `tools/Invoke-WUOGraphRequests.ps1` shows each request, asks for confirmation, substitutes saved ids and supports `-WhatIf`. |

Least-privilege Graph permissions: `DeviceManagementScripts.ReadWrite.All` (create and assign Remediations), `Group.Read.All` (resolve groups), `DeviceManagementManagedDevices.Read.All` (read status), and `DeviceManagementApps.ReadWrite.All` only if you also upload the Win32 app. Prefer delegated sign-in as the administrator over app-only secrets. The Intune health-script APIs are in the Graph **beta** endpoint.

The encrypted `.intunewin` upload for the Win32 app is **not** covered by the MCP server. Use the admin center, or a Win32 upload tool such as the community IntuneWin32App PowerShell module.

## 5. Interpreting a device

Status lines start with `WUO|v1|`: `Compliant`, `NonCompliant` (with `F=` finding ids, `+N` means more did not fit), `Remediated` (with `Fixed=`, `Failed=`, `Suppressed=`, `AdminAction=`), `Disabled`, `NoAction`, `Error`. The standalone package shows `Mode=Script`. Pass them to `wuo_interpret_status`. A detection-only package never changes anything. A fix that keeps being undone is suppressed after `FixMaxRepeats` and reported: look for the policy, baseline or tool that undoes it. `WaaSMedicSvc` fixes are expected to fail (Windows protects that service).

## 6. Operating

- **Kill switch:** `wuo_package_requests` action `disable-fixes` for the affected groups (detection keeps reporting), or remove the remediation script from the package. Win32 edition: assign `IntuneWUO-Config-Off`.
- **Rollback:** unassign or delete the package. It installs nothing and changes no Intune or Autopatch policy, so nothing else needs reverting.
- **Feature updates** (for example 24H2 to 25H2) are Autopatch's job. Intune-WUO never installs them; it reports blockers only.
- **Success:** at least 95% of in-scope devices on the latest approved quality update (or current hotpatch) within ring deadline + 7 days; Autopatch Not ready/alerted count falling; no blocker older than 14 days.

## 7. Standalone package through Graph (beta)

`wuo_package_requests` produces all of these for you. Without the MCP server, these are the calls. Show the human each request and wait for an explicit yes before sending it.

1. Read first: `GET /deviceManagement/deviceHealthScripts` (no existing `Intune-WUO`), the pilot group id, and its members.
2. Create: `POST /deviceManagement/deviceHealthScripts` with `displayName`, `description`, `publisher`, `runAsAccount: "system"`, `runAs32Bit: false`, `enforceSignatureCheck: false`, `roleScopeTagIds: ["0"]`, and `detectionScriptContent` = base64 of the file's exact bytes (UTF-8, no BOM). Leave `remediationScriptContent` out for detection only. The script is about 70 KB: send it from a file, not pasted through chat.
3. Assign: `POST /deviceManagement/deviceHealthScripts/{id}/assign` with `deviceHealthScriptAssignments: [{ target: { "@odata.type": "#microsoft.graph.groupAssignmentTarget", groupId }, runRemediationScript: false, runSchedule: { "@odata.type": "#microsoft.graph.deviceHealthScriptHourlySchedule", interval: 1..23 } }]`. This replaces the whole assignment list.
4. Verify: read back the script (compare a SHA-256 of the decoded content with the file) and `GET .../assignments`.
5. Results: `GET .../deviceHealthScripts/{id}/deviceRunStates?$expand=managedDevice($select=deviceName)`; the status line is `preRemediationDetectionScriptOutput`. Devices pick up a new package within 8 hours, or when the Intune Management Extension restarts.
6. Turn on fixes later: `PATCH` the script with `remediationScriptContent`, then re-assign with `runRemediationScript: true`. All six steps have been run against a test tenant. In that test, after an `assign` to the built-in All devices target, `GET .../assignments` still returned `runRemediationScript: false`: confirm in the admin center that the assignment shows the remediation script as on, and check `remediationState` in `deviceRunStates` after the next run.

## Facts that are easy to get wrong

- Update ring and WUfB policy reach devices over the MDM channel (Policy CSP), **not** through the Intune Management Extension. The IME only delivers scripts, Win32 apps and Remediations.
- Hourly Remediation schedules allow 1 to 23 hours; use 1 while piloting and 8 afterwards.
- The standalone detection script exits 1 on any Warning or Critical finding (so detection-only reports *With issues*), and its status line shows `Mode=Script`.
- `Update/IgnoreWindowsUpdateGroupPolicies = 1` (Windows 11 24H2 with KB5101684, build 26100.8973+) is the clean fix for leftover Group Policy. Intune-WUO only reports GPO/WSUS conflicts and never deletes domain Group Policy values.
- Hotpatch needs Windows 11 24H2+, VBS running, Arm64 needs CHPE disabled. Intune-WUO reports blockers only.
- An overdue update's age counts from its release date plus the ring's `DeferQualityUpdatesPeriodInDays`, then the ring's quality deadline (default 7) plus `FallbackGraceDays` (default 3). The KB number is in the `IntuneWUO` event log and the JSON log on the device, not in the Intune status line.
- Known limits today: policy-key fixes are not active (no GPO-vs-local attribution), hotpatch enrollment is not read, an overdue-update install by the remediation script has not yet been observed through Intune, and the validation harness (`tools/Invoke-WUOValidation.ps1`) drives the Win32 edition. Say so honestly if the user asks what is proven.
