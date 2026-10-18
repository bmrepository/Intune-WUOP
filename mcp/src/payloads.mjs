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
  FixSyncAndCleanup: { type: 'switch', def: 1 }
};

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
