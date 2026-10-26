// Builds Microsoft Graph (beta) request bodies for deploying Intune-WUO. Pure data: this server never calls Graph.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { readRepoFile } from './content.mjs';

export const GRAPH = 'https://graph.microsoft.com/beta';
export const PERMISSION = 'DeviceManagementScripts.ReadWrite.All';
export const MODES = ['Off', 'ReportOnly', 'Remediate', 'RemediateAndFallback'];

// Mirrors src/IntuneWUO/Public/Config.ps1 (a test checks they stay in sync).
export const SETTINGS = {
  FallbackGraceDays: { type: 'int', min: 0, max: 30, def: 3 },
  FallbackMaxAttempts: { type: 'int', min: 1, max: 10, def: 3 },
  MinFreeDiskGB: { type: 'int', min: 1, max: 500, def: 20 },
  ResetCooldownDays: { type: 'int', min: 1, max: 90, def: 7 },
  SyncStaleHours: { type: 'int', min: 1, max: 720, def: 24 },
  ScanStaleDays: { type: 'int', min: 1, max: 90, def: 7 },
  FixMaxRepeats: { type: 'int', min: 1, max: 10, def: 3 },
  FixServices: { type: 'switch', def: 1 },
  FixPauses: { type: 'switch', def: 1 },
  FixPolicyKeys: { type: 'switch', def: 1 },
  FixSyncAndCleanup: { type: 'switch', def: 1 },
  FixResetStack: { type: 'switch', def: 0 },
  InstallOverdueUpdates: { type: 'switch', def: 0 }   // the standalone scripts ship with 1
};

// The recommended edition: one Remediations package built from these two self-contained scripts.
export const STANDALONE = {
  displayName: 'Intune-WUO',
  detect: 'remediation/Detect-IntuneWUO.ps1',
  remediate: 'remediation/Remediate-IntuneWUO.ps1',
  // Settings that exist in the $WUOSettings block at the top of both scripts.
  settings: ['FixServices', 'FixPauses', 'FixSyncAndCleanup', 'InstallOverdueUpdates', 'FixResetStack', 'FallbackGraceDays',
    'FallbackMaxAttempts', 'MinFreeDiskGB', 'ResetCooldownDays', 'SyncStaleHours', 'ScanStaleDays', 'FixMaxRepeats']
};
export const STANDALONE_ACTIONS = ['create', 'enable-fixes', 'add-groups', 'disable-fixes', 'update-scripts', 'remove'];

/** UTF-8 without BOM, as required when "Enforce script signature check" is on. */
export function toBase64(text) {
  return Buffer.from(text.replace(/^﻿/, ''), 'utf8').toString('base64');
}

export function validateSettings(settings = {}) {
  const lines = [];
  for (const [name, value] of Object.entries(settings)) {
    const rule = SETTINGS[name];
    if (!rule) throw new Error(`Unknown setting '${name}'. Known: ${Object.keys(SETTINGS).join(', ')}`);
    const n = Number(value);
    if (!Number.isInteger(n)) throw new Error(`Setting ${name} must be a whole number.`);
    if (rule.type === 'switch' && ![0, 1].includes(n)) throw new Error(`Setting ${name} must be 0 or 1.`);
    if (rule.type === 'int' && (n < rule.min || n > rule.max)) throw new Error(`Setting ${name} must be between ${rule.min} and ${rule.max}.`);
    lines.push(`    ${name} = ${n}`);
  }
  return lines;
}

/** Same stamping as build/Build-IntuneWUO.ps1: Mode first, then any extra settings. */
export function stampConfigScript(template, mode, settings = {}) {
  if (!MODES.includes(mode)) throw new Error(`Unknown mode '${mode}'. Use one of ${MODES.join(', ')}.`);
  const lines = [`    Mode = '${mode}'`, ...validateSettings(settings)];
  return template.replace('__SETTINGS__', lines.join('\n'));
}

async function loadScript(rel, scriptsDir) {
  // A locally built (for example signed) copy wins over the repository copy.
  if (scriptsDir) return (await readFile(path.join(scriptsDir, path.basename(rel)), 'utf8')).replace(/^﻿/, '');
  return readRepoFile(rel);
}

const group = (groupId) => ({
  '@odata.type': '#microsoft.graph.deviceHealthScriptAssignment',
  target: { '@odata.type': '#microsoft.graph.groupAssignmentTarget', groupId }
});

const hourly = (interval) => ({ '@odata.type': '#microsoft.graph.deviceHealthScriptHourlySchedule', interval });
const daily = (time = '12:00:00.0000000') => ({ '@odata.type': '#microsoft.graph.deviceHealthScriptDailySchedule', interval: 1, useUtc: false, time });

export function assignmentBody(includeGroupIds, excludeGroupIds = [], schedule) {
  const items = [
    ...includeGroupIds.map((id) => ({ ...group(id), runRemediationScript: true, runSchedule: schedule })),
    ...excludeGroupIds.map((id) => ({
      '@odata.type': '#microsoft.graph.deviceHealthScriptAssignment',
      target: { '@odata.type': '#microsoft.graph.exclusionGroupAssignmentTarget', groupId: id },
      runRemediationScript: false
    }))
  ];
  return { deviceHealthScriptAssignments: items };
}

const common = (displayName, description, detect, remediate, { enforceSignatureCheck = false, version = '1.0.0' } = {}) => ({
  '@odata.type': '#microsoft.graph.deviceHealthScript',
  displayName,
  description,
  publisher: 'Intune-WUO',
  version,
  runAsAccount: 'system',
  runAs32Bit: false,          // must be 64-bit: registry views and PSWindowsUpdate
  enforceSignatureCheck,
  roleScopeTagIds: ['0'],
  isGlobalScript: false,
  deviceHealthScriptType: 'deviceHealthScript',
  detectionScriptContent: toBase64(detect),
  remediationScriptContent: toBase64(remediate)
});

/**
 * Requests that create one config package per requested mode and assign it.
 * Each device must receive exactly one config package, so assign a group to one mode at a time.
 */
export async function buildConfigPackageRequests({ modes = ['ReportOnly'], assignments = {}, excludeGroupIds = [], settings = {}, version = '1.0.0', scriptsDir } = {}) {
  const tpl = {
    detect: await readRepoFile('src/Config/Config.Detect.template.ps1'),
    remediate: await readRepoFile('src/Config/Config.Remediate.template.ps1')
  };
  const requests = [];
  for (const mode of modes) {
    const key = `configScriptId_${mode}`;
    requests.push({
      description: `Create config package IntuneWUO-Config-${mode} (writes HKLM\\SOFTWARE\\IntuneWUO\\Mode = ${mode})`,
      method: 'POST',
      url: `${GRAPH}/deviceManagement/deviceHealthScripts`,
      body: common(`IntuneWUO-Config-${mode}`, `Sets the Intune-WUO mode to ${mode}. Assign each device to exactly one IntuneWUO-Config package.`,
        stampConfigScript(tpl.detect, mode, settings), stampConfigScript(tpl.remediate, mode, settings), { version }),
      saveResponseIdAs: key,
      requiresPermission: PERMISSION,
      writes: true
    });
    const groups = assignments[mode] ?? [];
    requests.push({
      description: groups.length ? `Assign IntuneWUO-Config-${mode} to ${groups.length} group(s), run daily` : `Assign IntuneWUO-Config-${mode} (no groups yet: supply group ids before sending)`,
      method: 'POST',
      url: `${GRAPH}/deviceManagement/deviceHealthScripts/{${key}}/assign`,
      body: assignmentBody(groups, excludeGroupIds, daily()),
      dependsOn: key,
      requiresPermission: PERMISSION,
      writes: true,
      skipIfNoGroups: groups.length === 0
    });
  }
  return requests;
}

/** Requests that create the main detect/remediate Remediation and assign it every 8 hours. */
export async function buildRemediationRequests({ includeGroupIds = [], excludeGroupIds = [], enforceSignatureCheck = false, version = '1.0.0', scriptsDir, intervalHours = 8 } = {}) {
  if (intervalHours < 1 || intervalHours > 23) throw new Error('Hourly schedules allow 1 to 23 hours.');
  const detect = await loadScript('src/Remediation/Detect-WUO.ps1', scriptsDir);
  const remediate = await loadScript('src/Remediation/Remediate-WUO.ps1', scriptsDir);
  return [
    {
      description: 'Create the IntuneWUO-DetectRemediate Remediation (runs as SYSTEM, 64-bit)',
      method: 'POST',
      url: `${GRAPH}/deviceManagement/deviceHealthScripts`,
      body: common('IntuneWUO-DetectRemediate', 'Detects and fixes Windows Update blockers for Autopatch-managed devices. Behaviour is controlled by the IntuneWUO-Config package (mode).', detect, remediate, { enforceSignatureCheck, version }),
      saveResponseIdAs: 'mainScriptId',
      requiresPermission: PERMISSION,
      writes: true
    },
    {
      description: `Assign IntuneWUO-DetectRemediate to ${includeGroupIds.length} group(s), every ${intervalHours} hours`,
      method: 'POST',
      url: `${GRAPH}/deviceManagement/deviceHealthScripts/{mainScriptId}/assign`,
      body: assignmentBody(includeGroupIds, excludeGroupIds, hourly(intervalHours)),
      dependsOn: 'mainScriptId',
      requiresPermission: PERMISSION,
      writes: true,
      skipIfNoGroups: includeGroupIds.length === 0
    }
  ];
}

/**
 * Moving groups between modes. Graph's assign action REPLACES a package's whole assignment list, so the
 * caller must read the current assignments first. Given them, this computes the exact bodies.
 * @param {{fromMode:string,toMode:string,groupIds:string[],current?:Record<string,string[]>, excludeGroupIds?:string[]}} o
 */
export function buildModeChange({ fromMode, toMode, groupIds, current, excludeGroupIds = [] }) {
  for (const m of [fromMode, toMode]) if (!MODES.includes(m)) throw new Error(`Unknown mode '${m}'.`);
  if (fromMode === toMode) throw new Error('fromMode and toMode are the same.');
  if (!groupIds?.length) throw new Error('Provide at least one group id.');

  const reads = [fromMode, toMode].map((m) => ({
    description: `Read the current assignments of IntuneWUO-Config-${m}`,
    method: 'GET',
    url: `${GRAPH}/deviceManagement/deviceHealthScripts/{configScriptId_${m}}/assignments`,
    writes: false,
    requiresPermission: PERMISSION
  }));
  if (!current || !current[fromMode] || !current[toMode]) {
    return { needsCurrentAssignments: true, message: 'Read the current assignments (group ids) of both packages, then call again with currentAssignments = { <fromMode>: [...], <toMode>: [...] }. The assign action replaces the whole list, so guessing would drop other groups.', requests: reads };
  }
  const remaining = current[fromMode].filter((id) => !groupIds.includes(id));
  const target = [...new Set([...current[toMode], ...groupIds])];
  return {
    needsCurrentAssignments: false,
    message: 'Assign the target package first, then update the source, so a device is never without a config package.',
    requests: [
      { description: `Add ${groupIds.length} group(s) to IntuneWUO-Config-${toMode}`, method: 'POST', url: `${GRAPH}/deviceManagement/deviceHealthScripts/{configScriptId_${toMode}}/assign`, body: assignmentBody(target, excludeGroupIds, daily()), writes: true, requiresPermission: PERMISSION },
      { description: `Remove them from IntuneWUO-Config-${fromMode}`, method: 'POST', url: `${GRAPH}/deviceManagement/deviceHealthScripts/{configScriptId_${fromMode}}/assign`, body: assignmentBody(remaining, excludeGroupIds, daily()), writes: true, requiresPermission: PERMISSION }
    ]
  };
}

/**
 * Reference metadata for the Win32 app. The .intunewin content upload (encrypt, Azure Storage upload, commit)
 * is NOT covered here: use the Intune admin center or a Win32-upload tool such as the IntuneWin32App module.
 */
export function buildWin32AppReference({ version = '1.0.0' } = {}) {
  return {
    note: 'Metadata only. Upload IntuneWUO.intunewin with the admin center or a tool that handles the encrypted upload, then add the detection script and assignments.',
    adminCenterSettings: {
      name: 'Intune-WUO',
      publisher: 'Intune-WUO',
      version,
      installCommand: '%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Install-IntuneWUO.ps1',
      uninstallCommand: '%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Uninstall-IntuneWUO.ps1',
      installBehavior: 'System',
      deviceRestartBehavior: 'No specific action',
      detectionRule: 'Custom script: out\\Win32-Detect\\Detect-IntuneWUOApp.ps1 (version-stamped by the build)',
      requirements: '64-bit, Windows 11',
      assignment: 'Required: pilot group first, then ring groups. Excluded: the excluded-devices group.'
    },
    graphMetadata: {
      '@odata.type': '#microsoft.graph.win32LobApp',
      displayName: 'Intune-WUO',
      description: 'Intune-WUO engine and fallback task for Windows Update orchestration.',
      publisher: 'Intune-WUO',
      displayVersion: version,
      installCommandLine: '%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Install-IntuneWUO.ps1',
      uninstallCommandLine: '%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Uninstall-IntuneWUO.ps1',
      setupFilePath: 'Install-IntuneWUO.ps1',
      applicableArchitectures: 'x64',
      installExperience: { '@odata.type': 'microsoft.graph.win32LobAppInstallExperience', runAsAccount: 'system', deviceRestartBehavior: 'suppress', maxRunTimeInMinutes: 15 },
      roleScopeTagIds: ['0']
    }
  };
}

// ---------------------------------------------------------------------------------------------------------
// Standalone Remediations package (recommended edition)
// ---------------------------------------------------------------------------------------------------------

/** Changes values in the $WUOSettings block of a standalone script. Both scripts must get the same values. */
export function applyStandaloneSettings(script, settings = {}) {
  validateSettings(settings);
  const start = script.indexOf('$WUOSettings = @{');
  const end = start === -1 ? -1 : script.indexOf('\n}', start);
  if (start === -1 || end === -1) throw new Error('The $WUOSettings block was not found in the script.');
  let block = script.slice(start, end);
  for (const [name, value] of Object.entries(settings)) {
    if (!STANDALONE.settings.includes(name)) throw new Error(`Setting '${name}' is not in the standalone scripts. Use one of: ${STANDALONE.settings.join(', ')}`);
    const re = new RegExp(`^(\\s+${name}\\s*=\\s*)\\d+`, 'm');
    if (!re.test(block)) throw new Error(`Setting '${name}' was not found in the $WUOSettings block.`);
    block = block.replace(re, `$1${Number(value)}`);
  }
  return script.slice(0, start) + block + script.slice(end);
}

/** The two scripts, with any setting changes applied, and the version stamped in their header. */
export async function loadStandaloneScripts({ settings = {}, scriptsDir } = {}) {
  const detect = applyStandaloneSettings(await loadScript(STANDALONE.detect, scriptsDir), settings);
  const remediate = applyStandaloneSettings(await loadScript(STANDALONE.remediate, scriptsDir), settings);
  const version = /\$WUOScriptVersion = '([^']+)'/.exec(detect)?.[1] ?? 'unknown';
  return { detect, remediate, version };
}

/** Assignment list for the standalone package. runRemediationScript is per group, so rings can be staged. */
export function standaloneAssignmentBody(groups, excludeGroupIds = [], intervalHours = 1) {
  if (intervalHours < 1 || intervalHours > 23) throw new Error('Hourly schedules allow 1 to 23 hours.');
  return {
    deviceHealthScriptAssignments: [
      ...groups.map((g) => ({ ...group(g.groupId), runRemediationScript: Boolean(g.fixes), runSchedule: hourly(intervalHours) })),
      ...excludeGroupIds.map((id) => ({
        '@odata.type': '#microsoft.graph.deviceHealthScriptAssignment',
        target: { '@odata.type': '#microsoft.graph.exclusionGroupAssignmentTarget', groupId: id },
        runRemediationScript: false
      }))
    ]
  };
}

/**
 * Graph requests for one step of the standalone package's life. NOTHING is sent.
 * Graph's assign action replaces the whole assignment list, so every step except 'create' and 'update-scripts'
 * needs the current assignments: call without currentAssignments to get the read request, then again with them.
 * @param {object} o
 * @param {'create'|'enable-fixes'|'add-groups'|'disable-fixes'|'update-scripts'|'remove'} o.action
 * @param {string[]} [o.groupIds]  the pilot for create; otherwise the groups this step changes
 * @param {{groupId:string, fixes:boolean}[]} [o.currentAssignments]  read from GET .../assignments
 */
export async function buildStandaloneRequests({
  action = 'create', packageId, groupIds = [], currentAssignments, excludeGroupIds = [], intervalHours = 1,
  fixes = false, settings = {}, signed = false, scriptsDir
} = {}) {
  if (!STANDALONE_ACTIONS.includes(action)) throw new Error(`action must be one of: ${STANDALONE_ACTIONS.join(', ')}`);
  const scripts = await loadStandaloneScripts({ settings, scriptsDir });
  const pkgUrl = `${GRAPH}/deviceManagement/deviceHealthScripts/${packageId ?? '{packageId}'}`;
  const read = (description, url) => ({ description, method: 'GET', url, writes: false, requiresPermission: PERMISSION });
  const verify = [
    read('Verify: read the assignments back', `${pkgUrl}/assignments`),
    read('Results: one row per device; the status line is preRemediationDetectionScriptOutput', `${pkgUrl}/deviceRunStates?$expand=managedDevice($select=deviceName,osVersion)`)
  ];
  const assign = (groups, description) => ({
    description, method: 'POST', url: `${pkgUrl}/assign`,
    body: standaloneAssignmentBody(groups, excludeGroupIds, intervalHours), writes: true, requiresPermission: PERMISSION
  });
  const scriptBody = (withRemediation) => ({
    '@odata.type': '#microsoft.graph.deviceHealthScript', version: scripts.version,
    detectionScriptContent: toBase64(scripts.detect),
    ...(withRemediation ? { remediationScriptContent: toBase64(scripts.remediate) } : {})
  });
  const changed = Object.entries(settings).map(([k, v]) => `${k}=${v}`).join(', ');
  const notes = [
    'Nothing here has been sent. Show each write to the human and send it only after an explicit yes.',
    `Scripts: ${STANDALONE.detect} and ${STANDALONE.remediate}, version ${scripts.version}${changed ? `, with settings changed: ${changed}` : ''}.`,
    'Each script is about 70 KB. Send the content from a file with your own tool; do not paste it through the chat.',
    `Required Graph permission: ${PERMISSION}. The health-script APIs are in the Graph beta endpoint.`,
    'After an assign, also check the assignment in the admin center: in testing, Graph read back runRemediationScript: false after it was set to true on the built-in All devices target.'
  ];

  if (action === 'create') {
    if (!groupIds.length) notes.push('No pilot group id given: the assign request has a placeholder. Never assign a first rollout to All devices.');
    const body = {
      ...scriptBody(false),
      displayName: STANDALONE.displayName,
      description: `Intune-WUO ${scripts.version} (github.com/bmrepository/Intune-WUOP). Detects what stops Windows Update and Autopatch from keeping the device current. Detection only = report. Add Remediate-IntuneWUO.ps1 to turn on fixes.`,
      publisher: 'Intune-WUO', runAsAccount: 'system', runAs32Bit: false, enforceSignatureCheck: signed, roleScopeTagIds: ['0']
    };
    return {
      action, version: scripts.version, notes,
      requests: [
        read(`Look for an existing ${STANDALONE.displayName} package (each device gets exactly one)`, `${GRAPH}/deviceManagement/deviceHealthScripts?$select=id,displayName,version&$filter=displayName eq '${STANDALONE.displayName}'`),
        { description: `Create the ${STANDALONE.displayName} package with the detection script only (report only)`, method: 'POST', url: `${GRAPH}/deviceManagement/deviceHealthScripts`, body, saveResponseIdAs: 'packageId', writes: true, requiresPermission: PERMISSION },
        assign((groupIds.length ? groupIds : ['<pilot-group-id>']).map((g) => ({ groupId: g, fixes: false })), `Assign to the pilot, detection only, every ${intervalHours} hour(s)`),
        ...verify
      ]
    };
  }

  if (action === 'update-scripts') {
    return {
      action, version: scripts.version,
      notes: [...notes, fixes ? 'Both scripts are replaced.' : 'Only the detection script is replaced. Pass fixes: true when the package already has the remediation script, so both stay on the same version and settings.'],
      requests: [{ description: `Replace the script content with version ${scripts.version}`, method: 'PATCH', url: pkgUrl, body: scriptBody(fixes), writes: true, requiresPermission: PERMISSION }, ...verify]
    };
  }

  if (!currentAssignments) {
    return {
      action, needsCurrentAssignments: true,
      notes: [...notes, 'Read the current assignments, then call again with currentAssignments = [{ groupId, fixes }] (fixes = runRemediationScript).'],
      requests: [read('Read the current assignments (the assign action replaces the whole list)', `${pkgUrl}/assignments`)]
    };
  }
  const current = currentAssignments.map((a) => ({ groupId: a.groupId, fixes: Boolean(a.fixes ?? a.runRemediationScript) }));
  const touched = new Set(groupIds);

  if (action === 'enable-fixes' || action === 'disable-fixes') {
    const on = action === 'enable-fixes';
    if (!groupIds.length) throw new Error('Name the group ids whose fixes you want to change.');
    const missing = groupIds.filter((g) => !current.some((c) => c.groupId === g));
    if (missing.length) throw new Error(`Not assigned yet: ${missing.join(', ')}. Use add-groups first.`);
    const next = current.map((c) => (touched.has(c.groupId) ? { ...c, fixes: on } : c));
    const requests = on ? [{ description: 'Add the remediation script to the package (and refresh the detection script to the same version)', method: 'PATCH', url: pkgUrl, body: scriptBody(true), writes: true, requiresPermission: PERMISSION }] : [];
    requests.push(assign(next, `Turn ${on ? 'on' : 'off'} fixes for ${groupIds.length} group(s); ${next.length - groupIds.length} other group(s) unchanged`));
    return { action, version: scripts.version, notes: on ? notes : [...notes, 'Fixes stop from the next run. Nothing needs undoing on devices: Intune-WUO changes no policy.'], requests: [...requests, ...verify] };
  }

  if (action === 'add-groups') {
    if (!groupIds.length) throw new Error('Name the group ids to add.');
    const next = [...current.filter((c) => !touched.has(c.groupId)), ...groupIds.map((g) => ({ groupId: g, fixes }))];
    return { action, version: scripts.version, notes, requests: [assign(next, `Add ${groupIds.length} group(s) ${fixes ? 'with fixes on' : 'detection only'}; keep the ${current.length} existing assignment(s)`), ...verify] };
  }

  // remove: take the named groups off the package, or every group when none are named.
  const next = groupIds.length ? current.filter((c) => !touched.has(c.groupId)) : [];
  return {
    action, version: scripts.version,
    notes: [...notes, 'Unassigning stops all runs on those devices. Nothing is installed on devices, so there is nothing else to remove.'],
    requests: [assign(next, groupIds.length ? `Remove ${groupIds.length} group(s); keep ${next.length}` : 'Remove every assignment (stops Intune-WUO everywhere)'), ...verify]
  };
}
