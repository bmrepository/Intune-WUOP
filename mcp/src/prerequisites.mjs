// Pure logic: turns what the admin (or the agent) knows about the tenant into blockers, warnings and recommendations.

/**
 * @param {object} t  Facts about the tenant. Every field is optional; "unknown" never blocks but is called out.
 * @param {'E3E5'|'BusinessPremium'|'Other'|'Unknown'} [t.windowsLicence]  Windows licence covering the users of the devices.
 * @param {boolean} [t.autopatchEnrolled]  Devices are registered with Windows Autopatch.
 * @param {boolean} [t.clientBrokerDeployed]  The Windows Autopatch Client Broker is deployed.
 * @param {boolean} [t.windows11]  All target devices run Windows 11.
 * @param {number}  [t.oldestWindowsBuild]  Lowest OS build in scope, e.g. 26100.
 * @param {boolean} [t.coManaged]  Some devices are co-managed with ConfigMgr.
 * @param {boolean} [t.windowsUpdateWorkloadOnIntune]  Co-management Windows Update policies workload is set to Intune.
 * @param {boolean} [t.hybridOrGpo]  Devices may receive domain Group Policy for Windows Update.
 * @param {boolean} [t.wsusRemnants]  WSUS or imaging policy leftovers are known to exist.
 * @param {'none'|'wdac'|'applocker'|'both'|'unknown'} [t.appControl]  Application control in force.
 * @param {boolean} [t.canSignScripts]  A code-signing certificate trusted by the devices is available.
 * @param {'none'|'read'|'write'|'unknown'} [t.graphAccess]  What the AI agent can do in the tenant.
 * @param {boolean} [t.pilotDevicesAvailable]  10-20 IT devices are available for a pilot.
 * @param {boolean} [t.testDeviceAvailable]  A disposable test device is available for validation.
 * @param {boolean} [t.hotpatchWanted]  Hotpatch is part of the Autopatch plan.
 */
export function checkPrerequisites(t = {}) {
  const blockers = [];
  const warnings = [];
  const recommendations = [];
  const unknown = [];

  const block = (id, message, fix) => blockers.push({ id, message, fix });
  const warn = (id, message, fix) => warnings.push({ id, message, fix });
  const rec = (message) => recommendations.push(message);

  // Licensing: Remediations are how the detect/fix script runs on schedule.
  if (t.windowsLicence === 'BusinessPremium' || t.windowsLicence === 'Other') {
    block('LICENCE_REMEDIATIONS',
      'Intune Remediations need Windows Enterprise E3/E5 (or Microsoft 365 F3/E3/E5, Education A3/A5, or VDA). Microsoft 365 Business Premium includes Autopatch but not Remediations.',
      'Obtain a qualifying licence for the users of the devices, or deploy the detect/remediate scripts another way (this project does not yet ship a non-Remediations scheduler).');
  } else if (!t.windowsLicence || t.windowsLicence === 'Unknown') {
    unknown.push('windowsLicence');
    warn('LICENCE_UNKNOWN', 'The Windows licence is unknown. Remediations need Enterprise E3/E5 or equivalent.', 'Check Intune admin center > Devices > Scripts and remediations: if Create script package is greyed out or asks for licence verification, the licence is insufficient.');
  }

  if (t.autopatchEnrolled === false) {
    warn('NOT_IN_AUTOPATCH', 'Intune-WUO is designed to work alongside Windows Autopatch. Without it the fallback installer has no approval signal and there is no ring to follow.', 'Register the devices with Windows Autopatch (Intune admin center > Devices > Windows updates) before the pilot, or run in ReportOnly/Remediate only.');
  } else if (t.autopatchEnrolled === undefined) {
    unknown.push('autopatchEnrolled');
  }

  if (t.clientBrokerDeployed === false) {
    rec('Deploy the Windows Autopatch Client Broker (Tenant administration > Windows Autopatch > Tenant management > Manage client broker). Intune-WUO then reports Autopatch readiness and the ring.');
  }

  if (t.windows11 === false || (typeof t.oldestWindowsBuild === 'number' && t.oldestWindowsBuild < 22000)) {
    block('OS_TOO_OLD', 'Intune-WUO targets Windows 11. Windows 10 devices are out of scope for the supported scripts.', 'Exclude Windows 10 devices with the excluded-devices group or an Intune filter.');
  }
  if (typeof t.oldestWindowsBuild === 'number' && t.oldestWindowsBuild >= 22000 && t.oldestWindowsBuild < 26100) {
    rec(`The oldest device is build ${t.oldestWindowsBuild}. Hotpatch and the IgnoreWindowsUpdateGroupPolicies policy need Windows 11 24H2 (26100) or later (26100.8973 for the policy).`);
  }
  if (t.hotpatchWanted && typeof t.oldestWindowsBuild === 'number' && t.oldestWindowsBuild < 26100) {
    warn('HOTPATCH_OS', 'Hotpatch requires Windows 11 24H2 (build 26100) or later; older devices will receive the normal cumulative update.', 'Upgrade or accept restarts on those devices.');
  }

  if (t.coManaged) {
    if (t.windowsUpdateWorkloadOnIntune === false) {
      block('COMANAGEMENT_WORKLOAD', 'Co-managed devices must have the Windows Update policies workload set to Intune (or Pilot Intune). Autopatch and Intune-WUO cannot control updates otherwise.', 'In ConfigMgr: Cloud Attach/Co-management > Workloads > Windows Update policies = Intune; also move Device configuration. Clear ConfigMgr client Software Updates settings.');
    } else if (t.windowsUpdateWorkloadOnIntune === undefined) {
      warn('COMANAGEMENT_UNKNOWN', 'Co-managed devices exist but the Windows Update workload state is unknown.', 'Confirm the workload is on Intune; Intune-WUO reports CONFIGMGR_PRESENT either way.');
    }
  }

  if (t.hybridOrGpo || t.wsusRemnants) {
    rec('Deploy the Intune policy Update/IgnoreWindowsUpdateGroupPolicies = 1 (Windows 11 24H2 with KB5101684, build 26100.8973 and later). This is the clean fix for leftover Group Policy; Intune-WUO only reports these conflicts.');
    rec('Run Intune-WUO in ReportOnly first: it will name the source of each conflict (POLICY_CONFLICT_*, WSUS_REMNANT, DUALSCAN_CONFLICT).');
  }

  if (t.appControl === 'wdac' || t.appControl === 'applocker' || t.appControl === 'both') {
    warn('APP_CONTROL', 'Application control is in force. The package installs to %ProgramFiles%\\IntuneWUO and may be blocked.', 'Allow the folder by signer (sign the scripts) or via the Intune managed installer. The update engine falls back to native Windows Update COM if the bundled PSWindowsUpdate cannot load.');
  } else if (t.appControl === undefined || t.appControl === 'unknown') {
    unknown.push('appControl');
    rec('Application control is unknown. The detect script reports language mode and code-integrity state; run the pilot in ReportOnly to see it.');
  }

  if (t.canSignScripts === false) {
    rec('Signing the scripts is optional but recommended (Remediations "Enforce script signature check", and app control). Without it, leave signature enforcement off.');
  }

  if (t.graphAccess === 'none' || t.graphAccess === undefined || t.graphAccess === 'unknown') {
    if (t.graphAccess === undefined || t.graphAccess === 'unknown') unknown.push('graphAccess');
    rec('The agent has no tenant access, so it will produce the plan and exact Graph requests, and a human performs them in the Intune admin center. See docs/AI-AGENTS.md to connect a Graph-capable MCP server.');
  } else if (t.graphAccess === 'read') {
    rec('The agent has read-only tenant access. It can verify groups, existing packages and assignments, but a human must perform the writes.');
  } else if (t.graphAccess === 'write') {
    warn('AGENT_WRITE_ACCESS', 'The agent can write to the tenant. Keep a human approval step before every write and start with a test tenant or the pilot group.', 'Use a least-privilege app registration (DeviceManagementScripts.ReadWrite.All for Remediations plus Group.Read.All), conditional access, and log every call.');
  }

  if (t.pilotDevicesAvailable === false) {
    block('NO_PILOT', 'A pilot of 10-20 IT devices is required before any ring is changed.', 'Create an Entra device group for the pilot and add IT-owned devices.');
  } else if (t.pilotDevicesAvailable === undefined) {
    unknown.push('pilotDevicesAvailable');
  }
  if (t.testDeviceAvailable === false) {
    warn('NO_TEST_DEVICE', 'No disposable test device for tools/Invoke-WUOValidation.ps1. The fixes and the fallback have only been unit-tested with mocks.', 'Validate on an IT-owned device before the pilot; the harness restores what it changes.');
  }

  rec('Start every group in ReportOnly. Move a group to Remediate only after a clean cycle, and enable RemediateAndFallback last, ring by ring.');
  rec('Record a baseline from the Autopatch reports (quality update compliance, Not ready devices) before the pilot so success can be measured.');

  const ready = blockers.length === 0;
  return {
    ready,
    verdict: ready ? (warnings.length ? 'Ready with warnings' : 'Ready') : 'Not ready: resolve the blockers first',
    blockers,
    warnings,
    recommendations,
    unknownFacts: [...new Set(unknown)],
    nextStep: ready
      ? 'Call wuo_plan_deployment with your group names/ids to get the ordered plan.'
      : 'Resolve the blockers, then call wuo_check_prerequisites again.'
  };
}
