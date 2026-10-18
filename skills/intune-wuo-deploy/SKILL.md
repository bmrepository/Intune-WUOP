---
name: intune-wuo-deploy
description: Plan, deploy and operate Intune-WUO, the open-source Windows Update orchestration layer for Intune-managed Windows devices that use Windows Autopatch. Use when the user wants to deploy, roll out, pilot, switch modes, validate or troubleshoot Intune-WUO / IntuneWUO / "WUO", or asks how to detect and fix Windows Update problems that block Autopatch-approved updates, or pastes a status line starting with WUO|v1|.
when_to_use: Examples - "deploy the Intune Windows Update orchestration project to my tenant", "move my Test ring to Remediate", "why is this device NonCompliant WUO|v1|...", "set up Intune Remediations for Autopatch blockers", "roll back Intune-WUO", "what does this finding mean".
---

# Deploy and operate Intune-WUO

Intune-WUO (https://github.com/bmrepository/Intune-WUOP) detects the device-side problems that stop Windows Autopatch-approved updates installing, fixes the safe ones, and as a last resort installs overdue **approved** quality updates. It never restarts a device, shows UI, changes update or Autopatch policy, installs drivers or feature updates, or changes VBS/CHPE.

Modes (set per device group through one `IntuneWUO-Config-<Mode>` package; each device gets exactly one): `Off` (kill switch), `ReportOnly` (default), `Remediate`, `RemediateAndFallback`.

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
| Graph bodies for the packages and Remediation | `wuo_generate_graph_requests` |
| Move groups between modes | `wuo_generate_mode_change` |
| Win32 app settings | `wuo_win32_app_reference` |
| Verify a phase | `wuo_validation_checklist` |
| Explain a device status line | `wuo_interpret_status`, `wuo_explain_finding`, `wuo_list_findings` |
| Any document | `wuo_get_doc` |

## 2. Workflow

1. **Orient and ask little.** Call `wuo_overview`. Ask the user only for facts you need (licence, Autopatch registration, group names/ids, co-management, app control, what tenant access you have), then call `wuo_check_prerequisites`. Stop and explain if there are blockers (the usual one: Remediations need Windows Enterprise E3/E5 or equivalent; Microsoft 365 Business Premium is not enough).
2. **Plan.** Call `wuo_plan_deployment` and show the user the phases. Do not skip phases.
3. **Build.** The package is built on a Windows machine with `build/Build-IntuneWUO.ps1` (see the plan, phase P1). Offer to run it if you have a shell on Windows; otherwise give the exact command. Recommend `tools/Invoke-WUOValidation.ps1` on a disposable test device first.
4. **Deploy phase by phase.** For tenant changes generate the requests, **show them to the human, and wait for an explicit yes for each batch** before sending anything.
5. **Verify** each phase with `wuo_validation_checklist` and the Intune device status.
6. **Promote** one stage at a time: pilot ReportOnly, pilot Remediate (2 patch cycles), then each Autopatch ring ReportOnly, Remediate, finally RemediateAndFallback. Never skip a stage.

## 3. Hard rules

- **Start with the pilot group in `ReportOnly`.** Never assign to All devices or All users.
- **Nothing is sent to a tenant without the human approving that exact batch.** If you have no tenant tool, hand the human the requests or the admin-center steps.
- **Read before you write.** Verify group ids; look for existing `IntuneWUO-*` objects to avoid duplicates.
- **Graph's `assign` action replaces the whole assignment list.** Read current assignments first (`wuo_generate_mode_change` does this in two calls). Assign the target package before removing the source, so a device is never without a config package.
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

Status lines start with `WUO|v1|`: `Compliant`, `NonCompliant` (with `F=` finding ids, `+N` means more did not fit), `Remediated`, `Disabled`, `NoAction`, `Error`. Pass them to `wuo_interpret_status`. In `ReportOnly` nothing is ever changed. A fix that keeps being undone is suppressed after `FixMaxRepeats` and reported: look for the policy, baseline or tool that undoes it. `WaaSMedicSvc` fixes are expected to fail (Windows protects that service).

## 6. Operating

- **Kill switch:** assign `IntuneWUO-Config-Off` to the affected group and use *Run remediation* for an urgent stop.
- **Rollback:** unassign the Remediation, set the Win32 app assignment to Uninstall. Intune-WUO changes no Intune or Autopatch policy, so nothing else needs reverting.
- **Success:** at least 95% of in-scope devices on the latest approved quality update (or current hotpatch) within ring deadline + 7 days; Autopatch Not ready/alerted count falling; no blocker older than 14 days.

## Facts that are easy to get wrong

- Update ring and WUfB policy reach devices over the MDM channel (Policy CSP), **not** through the Intune Management Extension. The IME only delivers scripts, Win32 apps and Remediations.
- Hourly Remediation schedules allow 1 to 23 hours; the project uses 8.
- `Update/IgnoreWindowsUpdateGroupPolicies = 1` (Windows 11 24H2 with KB5101684, build 26100.8973+) is the clean fix for leftover Group Policy. Intune-WUO only reports GPO/WSUS conflicts and never deletes domain Group Policy values.
- Hotpatch needs Windows 11 24H2+, VBS running, Arm64 needs CHPE disabled. Intune-WUO reports blockers only.
- Known limits today: policy-key fixes are not active (no GPO-vs-local attribution), hotpatch enrollment is not read, and the fixes/fallback have been validated with mocks plus a harness (`tools/Invoke-WUOValidation.ps1`) that you should run on a test device. Say so honestly if the user asks what is proven.
