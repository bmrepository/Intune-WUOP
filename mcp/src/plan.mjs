// Builds the ordered deployment plan. Pure data: nothing here touches a tenant.
import {
  MODES, PERMISSION,
  buildConfigPackageRequests, buildRemediationRequests, buildWin32AppReference
} from './payloads.mjs';

const idOrPlaceholder = (g, label) => g?.id ?? `<${label}-group-id>`;

export const ROLLOUT_STAGES = [
  { stage: 'pilot-reportonly', groups: 'pilot', mode: 'ReportOnly', wait: '1 Patch Tuesday cycle (at least 24 h for first reports)', exit: 'Every pilot device reports a WUO status line; findings reviewed; no unexpected Critical findings.' },
  { stage: 'pilot-remediate', groups: 'pilot', mode: 'Remediate', wait: '2 Patch Tuesday cycles', exit: 'No fix-related incidents; fixes applied are the ones expected; no Suppressed or Failed fixes you cannot explain.' },
  { stage: 'rings-reportonly', groups: 'each Autopatch ring in order: Test, First, Fast, Broad', mode: 'ReportOnly', wait: '1 cycle per ring', exit: 'Baseline findings per ring understood.' },
  { stage: 'rings-remediate', groups: 'each ring in the same order', mode: 'Remediate', wait: '1 cycle per ring', exit: 'Autopatch Not ready/alerted devices fall; no new incidents.' },
  { stage: 'rings-fallback', groups: 'each ring in the same order', mode: 'RemediateAndFallback', wait: '1 cycle per ring', exit: 'Fallback runs report NothingOverdue or install only approved overdue updates; no device more than 14 days with an open blocker.' }
];

// Standalone package: one package, and runRemediationScript per assignment decides report vs fix for each group.
export const STANDALONE_STAGES = [
  { stage: 'pilot-detect', groups: 'pilot', fixes: false, wait: '1 Patch Tuesday cycle (first results within 8 hours, or after an Intune Management Extension restart)', exit: 'Every pilot device reports a WUO|v1| status line; findings reviewed; no unexpected Critical findings.' },
  { stage: 'pilot-fix', groups: 'pilot', fixes: true, wait: '2 Patch Tuesday cycles', exit: 'No fix-related incidents; fixes applied are the ones expected; overdue updates installed without restarts.' },
  { stage: 'rings-detect', groups: 'each Autopatch ring in order (Test, then the middle rings, then Last)', fixes: false, wait: '1 cycle per ring', exit: 'Baseline findings per ring understood.' },
  { stage: 'rings-fix', groups: 'each ring in the same order', fixes: true, wait: '1 cycle per ring', exit: 'Autopatch Not ready/alerted devices fall; >= 95% of devices on the latest approved quality update within deadline + 7 days.' }
];

/** Builds the deployment plan. edition 'standalone' (default, recommended) or 'win32'. */
export function buildPlan(input = {}) {
  return (input.edition ?? 'standalone') === 'win32' ? buildWin32Plan(input) : buildStandalonePlan(input);
}

export function buildStandalonePlan(input = {}) {
  const { pilotGroup, ringGroups = [], excludedGroup, signed = false, hotpatch = false, graphAccess = 'none', repoUrl = 'https://github.com/bmrepository/Intune-WUOP' } = input;
  const needsGroupIds = [pilotGroup, ...ringGroups, excludedGroup].filter(Boolean).some((g) => !g.id);
  const raw = repoUrl.replace('https://github.com/', 'https://raw.githubusercontent.com/') + '/main/remediation/';
  const prepare = buildWin32Plan(input).phases[0];
  prepare.steps = prepare.steps.filter((s) => s.id !== 'P0.3').concat({
    id: 'P0.3', kind: 'manual', title: 'Create or confirm Entra device groups',
    details: `A pilot group of 10-20 IT devices${pilotGroup?.name ? ` (${pilotGroup.name})` : ''}, the Autopatch ring groups${ringGroups.length ? ` (${ringGroups.map((g) => g.name ?? g.id).join(', ')})` : ''}, and optionally an excluded-devices group (servers, kiosks, shared devices, multi-session/AVD, Windows 365, LTSC)${excludedGroup?.name ? ` (${excludedGroup.name})` : ''}.`,
    requires: ['Group.Read.All (to verify)'], verify: 'Group object ids recorded.'
  });
  prepare.steps.sort((a, b) => a.id.localeCompare(b.id));

  const phases = [
    prepare,
    {
      id: 'P1', title: 'Get the two scripts', goal: 'Have Detect-IntuneWUO.ps1 and Remediate-IntuneWUO.ps1, with the settings you want, identical in both.',
      steps: [
        { id: 'P1.1', kind: 'local', title: 'Download (or clone the repository)', commands: [`Invoke-WebRequest ${raw}Detect-IntuneWUO.ps1 -OutFile Detect-IntuneWUO.ps1`, `Invoke-WebRequest ${raw}Remediate-IntuneWUO.ps1 -OutFile Remediate-IntuneWUO.ps1`], details: 'Nothing else is needed: the scripts are self-contained and install nothing on devices.', verify: 'Both files start with the same Version in their header.' },
        { id: 'P1.2', kind: 'local', title: 'Review the settings block (optional)', details: 'The $WUOSettings block at the top of each script. Defaults: fixes on, overdue-update install on, update-stack reset off. Change both files the same way, or pass settings to wuo_package_requests and it does that for you.', verify: 'Same values in both scripts.' },
        ...(signed ? [{ id: 'P1.3', kind: 'local', title: 'Sign both scripts', commands: ['Set-AuthenticodeSignature .\\Detect-IntuneWUO.ps1, .\\Remediate-IntuneWUO.ps1 -Certificate (Get-Item Cert:\\CurrentUser\\My\\<thumbprint>)'], details: 'Then turn on Enforce script signature check on the package.', verify: 'Get-AuthenticodeSignature shows Valid.' }] : [])
      ],
      exitCriteria: 'Two scripts ready.'
    },
    {
      id: 'P2', title: 'Create the package, detection only, for the pilot', goal: 'Report only: nothing is changed on any device.',
      steps: [{ id: 'P2.1', kind: 'graph', title: 'Create Intune-WUO with the detection script and assign it to the pilot every hour', requestsFrom: 'wuo_package_requests (action: create)', details: 'Admin center equivalent: Devices > Scripts and remediations > Create. Run as SYSTEM: yes (logged-on credentials No); 64-bit PowerShell: Yes; signature check: No unless signed.', requiresApproval: true, requires: [PERMISSION], verify: 'Device status shows Pre-remediation detection output starting with WUO|v1| and Mode=Script.' }],
      exitCriteria: 'Every pilot device reports a status line.'
    },
    {
      id: 'P3', title: 'Read the pilot results', goal: 'Understand what the tool sees before it may change anything.',
      steps: [
        { id: 'P3.1', kind: 'manual', title: 'Read the status lines', details: 'Device status > Pre-remediation detection output (or GET deviceRunStates). Paste each line into wuo_interpret_status.', verify: 'Every finding is explained.' },
        { id: 'P3.2', kind: 'manual', title: 'Compare with Autopatch', details: 'Check the Autopatch reports (Not ready, alerts, quality update status) against the findings.', verify: 'No surprises.' }
      ],
      exitCriteria: 'Findings understood; no unexpected Critical findings.'
    },
    {
      id: 'P4', title: 'Turn on fixes for the pilot', goal: 'Add the remediation script and switch fixes on for the pilot assignment only.',
      steps: [{ id: 'P4.1', kind: 'graph', title: 'Add Remediate-IntuneWUO.ps1 and set runRemediationScript on the pilot assignment', requestsFrom: 'wuo_package_requests (action: enable-fixes, with the current assignments)', requiresApproval: true, requires: [PERMISSION], verify: 'The assignment shows the remediation script on in the admin center; devices with fixable issues report WUO|v1|Remediated or Issue fixed.' }],
      exitCriteria: 'Two clean Patch Tuesday cycles on the pilot.'
    },
    {
      id: 'P5', title: 'Roll out by ring', goal: 'Each ring first reports, then fixes. Never skip a stage.',
      steps: STANDALONE_STAGES.slice(2).map((s, i) => ({
        id: `P5.${i + 1}`, kind: 'graph', title: `${s.stage}: ${s.groups}, ${s.fixes ? 'fixes on' : 'detection only'}`,
        details: `Wait: ${s.wait}. Use wuo_package_requests action ${s.fixes ? 'enable-fixes' : 'add-groups'} with the current assignments (assign replaces the whole list). Move the schedule from every hour to every 8 hours once past the pilot (intervalHours: 8).`,
        requiresApproval: true, requires: [PERMISSION], verify: s.exit
      })),
      exitCriteria: 'Every ring assigned with fixes on; no open blocker older than 14 days.'
    },
    {
      id: 'P6', title: 'Operate', goal: 'Keep it safe and observable.',
      steps: [
        { id: 'P6.1', kind: 'manual', title: 'Stop fixes (kill switch)', details: 'wuo_package_requests action disable-fixes for the affected groups: detection keeps reporting, nothing is changed. To stop everything, action remove (or unassign in the admin center).' },
        { id: 'P6.2', kind: 'manual', title: 'Update to a new version', details: 'wuo_package_requests action update-scripts with fixes: true (both scripts), after the new version has run on the pilot.' },
        { id: 'P6.3', kind: 'manual', title: 'Success measures', details: '>= 95% of in-scope devices on the latest approved quality update or current hotpatch within ring deadline + 7 days; Autopatch Not ready/alerted count falling; no blocker older than 14 days.' },
        { id: 'P6.4', kind: 'manual', title: 'Rollback', details: 'Unassign or delete the package. Intune-WUO installs nothing and changes no Intune or Autopatch policy, so nothing else needs reverting.' }
      ],
      exitCriteria: 'Monitoring in place.'
    }
  ];

  if (hotpatch) {
    phases[0].steps.push({ id: 'P0.7', kind: 'manual', title: 'Hotpatch prerequisites', details: 'Windows 11 24H2+, VBS running, Arm64 needs CHPE disabled, and the device on the latest baseline. Intune-WUO reports blockers but never changes VBS or CHPE.', verify: 'No HOTPATCH_* findings on enrolled devices.' });
  }

  return {
    summary: {
      project: 'Intune-WUO', edition: 'standalone', repo: repoUrl, needsGroupIds, graphAccess, signed,
      note: 'This plan was generated offline. No tenant calls were made. Every write requires explicit human approval.'
    },
    guardrailsForAgent: guardrails('standalone'),
    phases
  };
}

export function buildWin32Plan(input = {}) {
  const {
    pilotGroup, ringGroups = [], excludedGroup, version = '1.0.0',
    signed = false, hotpatch = false, graphAccess = 'none', repoUrl = 'https://github.com/bmrepository/Intune-WUOP'
  } = input;

  const pilotId = idOrPlaceholder(pilotGroup, 'pilot');
  const excludeIds = excludedGroup ? [idOrPlaceholder(excludedGroup, 'excluded')] : [];
  const needsGroupIds = [pilotGroup, ...ringGroups, excludedGroup].filter(Boolean).some((g) => !g.id);

  const build = [
    `git clone ${repoUrl}.git`,
    'cd Intune-WUOP',
    `.\\build\\Build-IntuneWUO.ps1 -Version ${version}` +
      ' -PSWindowsUpdatePath <path-to-pinned-PSWindowsUpdate-2.2.1.5>   # optional; omit to use native Windows Update COM only' +
      (signed ? ' -CertThumbprint <code-signing-thumbprint>' : '') +
      ' -IntuneWinAppUtil <path-to-IntuneWinAppUtil.exe>   # optional; produces out\\IntuneWUO.intunewin'
  ];

  const phases = [
    {
      id: 'P0', title: 'Prepare the tenant', goal: 'Everything the tool relies on exists before any package is deployed.',
      steps: [
        { id: 'P0.1', kind: 'manual', title: 'Confirm licensing', details: 'Remediations need Windows Enterprise E3/E5 (or Microsoft 365 F3/E3/E5, A3/A5, VDA). Check Intune admin center > Devices > Scripts and remediations.', verify: 'Create script package is available.' },
        { id: 'P0.2', kind: 'manual', title: 'Record a baseline', details: 'Export the Autopatch quality-update and Autopatch management status reports; note the count of Not ready and alerted devices.', verify: 'Baseline saved with a date.' },
        { id: 'P0.3', kind: 'manual', title: 'Create or confirm Entra device groups', details: `Pilot group (10-20 IT devices)${pilotGroup?.name ? `: ${pilotGroup.name}` : ''}; the Autopatch ring groups${ringGroups.length ? `: ${ringGroups.map((g) => g.name).join(', ')}` : ''}; an excluded-devices group (servers, kiosks, shared devices, multi-session/AVD, Windows 365, LTSC)${excludedGroup?.name ? `: ${excludedGroup.name}` : ''}.`, requires: ['Group.Read.All (to verify)'], verify: 'Group object ids recorded.' },
        { id: 'P0.4', kind: 'manual', title: 'Deploy the Windows Autopatch Client Broker', details: 'Tenant administration > Windows Autopatch > Tenant management > Manage client broker. Lets Intune-WUO report Autopatch readiness and the ring.', verify: 'C:\\Program Files\\Windows Autopatch Client Broker exists on a pilot device.' },
        { id: 'P0.5', kind: 'manual', title: 'Deploy IgnoreWindowsUpdateGroupPolicies = 1 (recommended if hybrid, co-managed or GPO-managed)', details: 'Settings catalog > Windows Update > Ignore Windows Update Group Policies (Windows 11 24H2 with KB5101684, build 26100.8973 and later). This is the clean fix for leftover Group Policy; Intune-WUO only reports conflicts.', verify: 'PolicyManager\\current\\device\\Update\\IgnoreWindowsUpdateGroupPolicies = 1 on a pilot device.' },
        { id: 'P0.6', kind: 'manual', title: 'Confirm diagnostic data is Required or higher', details: 'Autopatch needs System/AllowTelemetry >= 1.', verify: 'No DIAGDATA_LOW findings later.' }
      ],
      exitCriteria: 'Groups exist, baseline recorded, licensing confirmed.'
    },
    {
      id: 'P1', title: 'Build the package (on a Windows machine)', goal: 'Produce the Win32 package, the Remediation scripts and the four config packages.',
      steps: [
        { id: 'P1.1', kind: 'local', title: 'Build', commands: build, details: 'Nothing is downloaded by the build. Supply a pinned PSWindowsUpdate copy yourself if you want that backend; otherwise the native Windows Update COM backend is used (fully supported).', verify: 'out\\Win32, out\\Remediation, out\\Config\\<Mode>, out\\Win32-Detect exist.' },
        { id: 'P1.2', kind: 'local', title: 'Validate on a disposable test device (strongly recommended)', commands: ['.\\tools\\Invoke-WUOValidation.ps1   # elevated PowerShell; restores what it changes'], details: 'Exercises install, every mode, the service and pause fixes, sync trigger, fallback and uninstall as SYSTEM.', verify: 'docs\\validation\\<host>-<time>.md shows all steps PASS.' }
      ],
      exitCriteria: 'Artifacts built; validation passed on a test device.'
    },
    {
      id: 'P2', title: 'Deploy the Win32 app to the pilot', goal: 'Install the engine and the scheduled task on pilot devices.',
      steps: [
        { id: 'P2.1', kind: 'manual', title: 'Upload IntuneWUO.intunewin and set the app options', details: 'The encrypted .intunewin upload is not covered by this server. Use the admin center or a Win32 upload tool (for example the IntuneWin32App PowerShell module).', reference: buildWin32AppReference({ version }), requires: ['DeviceManagementApps.ReadWrite.All'], requiresApproval: true, verify: 'App shows Installed on pilot devices; detection rule passes.' },
        { id: 'P2.2', kind: 'manual', title: 'Assign: Required to the pilot group, exclude the excluded-devices group', details: `Pilot group id: ${pilotId}.`, requiresApproval: true, verify: 'Device install status = Installed.' }
      ],
      exitCriteria: 'App installed on every pilot device.'
    },
    {
      id: 'P3', title: 'Create the config packages (mode switch)', goal: 'All four mode packages exist; only the pilot is assigned, to ReportOnly. Off stays unassigned, ready as the kill switch.',
      steps: [{ id: 'P3.1', kind: 'graph', title: 'Create IntuneWUO-Config-{Off, ReportOnly, Remediate, RemediateAndFallback} and assign the pilot to ReportOnly', requestsFrom: 'wuo_generate_graph_requests (scope: config)', requiresApproval: true, requires: [PERMISSION], verify: 'Each device receives exactly one config package; HKLM\\SOFTWARE\\IntuneWUO\\Mode = ReportOnly on pilot devices.' }],
      exitCriteria: 'Pilot devices have Mode = ReportOnly.'
    },
    {
      id: 'P4', title: 'Create the Detect/Remediate Remediation', goal: 'Run the detection every 8 hours as SYSTEM, 64-bit.',
      steps: [{ id: 'P4.1', kind: 'graph', title: 'Create IntuneWUO-DetectRemediate and assign it to the pilot (excluding the excluded group)', requestsFrom: 'wuo_generate_graph_requests (scope: remediation)', requiresApproval: true, requires: [PERMISSION], verify: 'Device status shows Pre-remediation detection output starting with WUO|v1|.' }],
      exitCriteria: 'Pilot devices report status lines.'
    },
    {
      id: 'P5', title: 'Observe the pilot in ReportOnly', goal: 'Understand what the tool sees before it is allowed to change anything.',
      steps: [
        { id: 'P5.1', kind: 'manual', title: 'Read the status lines', details: 'Intune admin center > Devices > Scripts and remediations > IntuneWUO-DetectRemediate > Device status. Paste each line into wuo_interpret_status.', verify: 'Every finding is explained.' },
        { id: 'P5.2', kind: 'manual', title: 'Compare with Autopatch', details: 'Check the Autopatch Not ready tab and alerts against the findings.', verify: 'No surprises.' }
      ],
      exitCriteria: 'Findings understood; no unexpected Critical findings.'
    },
    {
      id: 'P6', title: 'Roll out by ring', goal: 'Promote groups one stage at a time. Never skip a stage.',
      steps: ROLLOUT_STAGES.map((s, i) => ({
        id: `P6.${i + 1}`, kind: 'graph', title: `${s.stage}: ${s.groups} -> ${s.mode}`,
        details: `Wait: ${s.wait}. Move a group between modes with wuo_generate_mode_change (it needs the current assignments because Graph's assign action replaces the whole list).`,
        requiresApproval: true, requires: [PERMISSION], verify: s.exit
      })),
      exitCriteria: 'All rings on RemediateAndFallback with no open blockers older than 14 days.'
    },
    {
      id: 'P7', title: 'Operate', goal: 'Keep it safe and observable.',
      steps: [
        { id: 'P7.1', kind: 'manual', title: 'Kill switch', details: 'Assign the IntuneWUO-Config-Off package to the affected group (or all devices) and use Run remediation for an urgent stop. Every component checks Mode on every run.' },
        { id: 'P7.2', kind: 'manual', title: 'Success measures', details: '>= 95% of in-scope devices on the latest approved quality update or current hotpatch within ring deadline + 7 days; Autopatch Not ready/alerted count falling; no blocker older than 14 days.' },
        { id: 'P7.3', kind: 'manual', title: 'Rollback', details: 'Unassign the Remediation, set the Win32 app assignment to Uninstall. Intune-WUO never changes Intune or Autopatch policy, so nothing else needs to be reverted.' }
      ],
      exitCriteria: 'Monitoring in place.'
    }
  ];

  if (hotpatch) {
    phases[0].steps.push({ id: 'P0.7', kind: 'manual', title: 'Hotpatch prerequisites', details: 'Windows 11 24H2+, VBS running, Arm64 needs CHPE disabled, and the device on the latest baseline. Intune-WUO reports blockers but never changes VBS or CHPE.', verify: 'No HOTPATCH_* findings on enrolled devices.' });
  }

  return {
    summary: {
      project: 'Intune-WUO', edition: 'win32', repo: repoUrl, version, needsGroupIds,
      graphAccess, signed,
      note: 'This plan was generated offline. No tenant calls were made. Every write requires explicit human approval.'
    },
    guardrailsForAgent: guardrails('win32'),
    phases
  };
}

export function guardrails(edition = 'standalone') {
  return [
    'Show the human each batch of tenant writes (method, URL, body summary) and wait for an explicit yes before sending it.',
    'Start with the pilot group only. Never assign to All devices / All users.',
    'Read before you write: verify group ids and look for an existing Intune-WUO package (or IntuneWUO-* objects) to avoid duplicates.',
    'The Graph assign action replaces the whole assignment list. Always read the current assignments first.',
    edition === 'win32' ? 'Each device must receive exactly one IntuneWUO-Config package.' : 'Each device must receive exactly one Intune-WUO script package.',
    'Record the id of every object you create and report it back.',
    'Stop on the first unexpected error; do not retry writes blindly.',
    'Never read, copy or log the Autopatch ActionsFeedUri value (it contains a signed access token) or any tokens/secrets.',
    'Do not change update policy, Autopatch policy, VBS or CHPE yourself: Intune-WUO deliberately reports those and leaves them to Intune policy.',
    edition === 'win32' ? 'Prefer a test tenant or the pilot group; keep the Off config package ready as the kill switch.' : 'Prefer a test tenant or the pilot group; to stop fixes quickly, turn runRemediationScript off for the affected groups (detection keeps reporting).'
  ];
}

export async function buildGraphRequests({ scope = 'all', pilotGroupId, ringGroupIds = [], excludeGroupIds = [], startMode = 'ReportOnly', includeAllModes = true, settings = {}, signed = false, scriptsDir, version = '1.0.0', remediationGroupIds } = {}) {
  if (!['config', 'remediation', 'all'].includes(scope)) throw new Error("scope must be 'config', 'remediation' or 'all'.");
  const requests = [];
  if (scope === 'config' || scope === 'all') {
    const modes = includeAllModes ? MODES : [startMode];
    const assignments = {};
    if (pilotGroupId) assignments[startMode] = [pilotGroupId];
    requests.push(...await buildConfigPackageRequests({ modes, assignments, excludeGroupIds, settings, version }));
  }
  if (scope === 'remediation' || scope === 'all') {
    const include = remediationGroupIds ?? [pilotGroupId, ...ringGroupIds].filter(Boolean);
    requests.push(...await buildRemediationRequests({ includeGroupIds: include, excludeGroupIds, enforceSignatureCheck: signed, scriptsDir, version }));
  }
  return {
    notes: [
      'Nothing here has been sent. Review, get human approval, then send the requests in order.',
      'Requests with saveResponseIdAs: store the "id" from the response under that name and substitute it for the {name} placeholder in later URLs.',
      'Skip requests marked skipIfNoGroups until you have group ids.',
      `Required Graph permission: ${PERMISSION}. Intune health-script APIs are in the beta endpoint.`,
      'Payloads follow the published deviceHealthScript schema; the assignment shape is partly undocumented by Microsoft, so verify the first assignment in the admin center.'
    ],
    requests
  };
}

export function renderPlanMarkdown(plan) {
  const label = plan.summary.edition === 'win32' ? `Win32 app edition, v${plan.summary.version}` : 'standalone Remediations package';
  const out = [`# Intune-WUO deployment plan (${label})`, '', plan.summary.note, ''];
  if (plan.summary.needsGroupIds) out.push('> Some group ids are missing. Replace the `<...-group-id>` placeholders before any write.', '');
  out.push('## Rules for the agent', ...plan.guardrailsForAgent.map((g) => `- ${g}`), '');
  for (const p of plan.phases) {
    out.push(`## ${p.id}. ${p.title}`, `Goal: ${p.goal}`, '');
    for (const s of p.steps) {
      out.push(`- **${s.id} [${s.kind}]${s.requiresApproval ? ' (needs human approval)' : ''}** ${s.title}`);
      if (s.details) out.push(`  - ${s.details}`);
      if (s.commands) out.push('  - Commands:', ...s.commands.map((c) => `    - \`${c}\``));
      if (s.requestsFrom) out.push(`  - Requests: call ${s.requestsFrom}`);
      if (s.verify) out.push(`  - Verify: ${s.verify}`);
    }
    out.push('', `Exit criteria: ${p.exitCriteria}`, '');
  }
  return out.join('\n');
}
