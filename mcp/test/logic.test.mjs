import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { REPO_ROOT, extractSection, getDoc, readRepoFile } from '../src/content.mjs';
import { loadCatalogue, findFinding } from '../src/catalogue.mjs';
import { parseStatusLine, interpretStatus } from '../src/status.mjs';
import { checkPrerequisites } from '../src/prerequisites.mjs';
import { SETTINGS, MODES, toBase64, stampConfigScript, validateSettings, assignmentBody, buildConfigPackageRequests, buildRemediationRequests, buildModeChange, buildWin32AppReference } from '../src/payloads.mjs';
import { buildPlan, buildGraphRequests, renderPlanMarkdown, ROLLOUT_STAGES } from '../src/plan.mjs';
import { validationChecklist, PHASES } from '../src/validation.mjs';

// ---------------------------------------------------------------- content
test('extractSection returns a section up to the next heading of the same level and ignores code fences', () => {
  const md = '# T\n\n## A\nalpha\n```\n## not a heading\n```\n### A1\ndeep\n\n## B\nbeta\n';
  const a = extractSection(md, 'A');
  assert.match(a, /alpha/);
  assert.match(a, /not a heading/);
  assert.match(a, /deep/);
  assert.doesNotMatch(a, /beta/);
  assert.equal(extractSection(md, 'Missing'), null);
});

test('real README sections are found by short name', async () => {
  for (const s of ['modes', 'deployment-guide', 'registry-reference', 'checks-and-fixes', 'security']) {
    const out = await getDoc('readme', s);
    assert.ok(out.length > 200, `section ${s} should have content`);
  }
});

test('unknown document and section are rejected with helpful errors', async () => {
  await assert.rejects(() => getDoc('nope'), /Unknown document/);
  await assert.rejects(() => getDoc('readme', 'no-such-section'), /not found/);
});

test('readRepoFile refuses to leave the project', async () => {
  await assert.rejects(() => readRepoFile('../secrets.txt'), /outside the project/);
});

test('GitHub fallback: fetches, normalises line endings and BOM, caches, and reports HTTP errors', async () => {
  const http = await import('node:http');
  let hits = 0;
  const srv = http.createServer((req, res) => {
    hits++;
    if (req.url === '/docs/x.md') { res.writeHead(200).end('﻿line1\r\nline2\r\n'); return; }
    res.writeHead(404).end('nope');
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const prev = process.env.WUO_REMOTE_BASE;
  process.env.WUO_REMOTE_BASE = `http://127.0.0.1:${srv.address().port}/`;
  try {
    const a = await readRepoFile('docs/x.md', { source: 'github' });
    assert.equal(a, 'line1\nline2\n');
    await readRepoFile('docs/x.md', { source: 'github' });
    assert.equal(hits, 1, 'second read must come from the cache');
    await assert.rejects(() => readRepoFile('docs/missing.md', { source: 'github' }), /HTTP 404/);
  } finally {
    if (prev === undefined) delete process.env.WUO_REMOTE_BASE; else process.env.WUO_REMOTE_BASE = prev;
    await new Promise((r) => srv.close(r));
  }
});

test('local source never touches the network', async () => {
  await assert.rejects(() => readRepoFile('does/not/exist.md', { source: 'local' }), /not found in the local clone/);
});

// ---------------------------------------------------------------- catalogue + status
test('catalogue loads and every entry is complete', async () => {
  const c = await loadCatalogue();
  assert.ok(c.findings.length >= 20);
  for (const f of c.findings) for (const k of ['id', 'severity', 'autoFix', 'title', 'cause', 'toolAction', 'adminAction']) assert.ok(f[k], `${f.id}.${k}`);
  assert.equal(findFinding(c, 'disk_low').id, 'DISK_LOW');
});

test('parseStatusLine handles each documented format', () => {
  const nc = parseStatusLine('WUO|v1|NonCompliant|Mode=ReportOnly|Build=26100|Ring=Test|F=SVC_DISABLED_BITS,DISK_LOW+3');
  assert.equal(nc.result, 'NonCompliant');
  assert.equal(nc.mode, 'ReportOnly');
  assert.equal(nc.build, 26100);
  assert.equal(nc.ring, 'Test');
  assert.deepEqual(nc.findings, ['SVC_DISABLED_BITS', 'DISK_LOW']);
  assert.equal(nc.overflow, 3);

  const ok = parseStatusLine('WUO|v1|Compliant|Mode=Remediate|Build=26100');
  assert.deepEqual(ok.findings, []);

  const rem = parseStatusLine('WUO|v1|Remediated|Fixed=SVC_DISABLED_BITS|Failed=SVC_DISABLED_WaaSMedicSvc|Suppressed=');
  assert.deepEqual(rem.fixed, ['SVC_DISABLED_BITS']);
  assert.deepEqual(rem.failed, ['SVC_DISABLED_WaaSMedicSvc']);
  assert.deepEqual(rem.suppressed, []);

  const err = parseStatusLine('WUO|v1|Error|module | not found');
  assert.equal(err.error, 'module | not found');

  assert.deepEqual(parseStatusLine('WUO|v1|NoAction|Busy').notes, ['Busy']);
});

test('parseStatusLine rejects anything that is not a status line', () => {
  assert.throws(() => parseStatusLine('hello'), /Not an Intune-WUO status line/);
  assert.throws(() => parseStatusLine(''), /Not an Intune-WUO status line/);
});

test('interpretStatus explains findings, orders advice, and flags overflow and unknown ids', async () => {
  const c = await loadCatalogue();
  const r = interpretStatus(parseStatusLine('WUO|v1|NonCompliant|Mode=ReportOnly|Build=26100|F=POLICY_CONFLICT_NOAUTOUPDATE,SVC_DISABLED_BITS,MADE_UP+2'), c);
  assert.equal(r.summary.counts.critical, 1);
  assert.equal(r.findings.find((f) => f.id === 'MADE_UP').severity, 'Unknown');
  const advice = r.nextSteps.join('\n');
  assert.match(advice, /Critical/);
  assert.match(advice, /ReportOnly, so nothing was changed/);
  assert.match(advice, /2 more finding/);
});

test('interpretStatus covers Compliant, Disabled, Remediated and Error', async () => {
  const c = await loadCatalogue();
  assert.match(interpretStatus(parseStatusLine('WUO|v1|Compliant|Mode=Remediate|Build=1'), c).explanation, /Compliant/);
  assert.match(interpretStatus(parseStatusLine('WUO|v1|Disabled|Mode=Off|Build=1'), c).explanation, /Off/);
  const rem = interpretStatus(parseStatusLine('WUO|v1|Remediated|Fixed=SYNC_STALE|Failed=SVC_DISABLED_WaaSMedicSvc|Suppressed=PAUSE_QUALITY_USER'), c);
  assert.equal(rem.summary.fixed, 1);
  assert.match(rem.nextSteps.join(' '), /protected by Windows/);
  assert.match(interpretStatus(parseStatusLine('WUO|v1|Error|boom'), c).explanation, /boom/);
});

// ---------------------------------------------------------------- prerequisites
test('Business Premium is a blocker (no Remediations), E3/E5 is not', () => {
  assert.equal(checkPrerequisites({ windowsLicence: 'BusinessPremium' }).blockers[0].id, 'LICENCE_REMEDIATIONS');
  assert.equal(checkPrerequisites({ windowsLicence: 'E3E5', pilotDevicesAvailable: true }).ready, true);
});

test('unknown facts never block but are listed', () => {
  const r = checkPrerequisites({});
  assert.equal(r.ready, true);
  assert.ok(r.unknownFacts.includes('windowsLicence'));
  assert.ok(r.warnings.some((w) => w.id === 'LICENCE_UNKNOWN'));
});

test('co-management with the workload on ConfigMgr blocks; GPO suggests IgnoreWindowsUpdateGroupPolicies', () => {
  assert.ok(checkPrerequisites({ coManaged: true, windowsUpdateWorkloadOnIntune: false }).blockers.some((b) => b.id === 'COMANAGEMENT_WORKLOAD'));
  assert.match(checkPrerequisites({ hybridOrGpo: true }).recommendations.join(' '), /IgnoreWindowsUpdateGroupPolicies/);
});

test('app control, write access and missing pilot are handled', () => {
  const r = checkPrerequisites({ appControl: 'wdac', graphAccess: 'write', pilotDevicesAvailable: false, windows11: false });
  const ids = [...r.blockers, ...r.warnings].map((x) => x.id);
  for (const id of ['APP_CONTROL', 'AGENT_WRITE_ACCESS', 'NO_PILOT', 'OS_TOO_OLD']) assert.ok(ids.includes(id), id);
  assert.equal(r.ready, false);
});

// ---------------------------------------------------------------- payloads
test('settings table matches src/IntuneWUO/Public/Config.ps1', async () => {
  const ps = await readFile(path.join(REPO_ROOT, 'src', 'IntuneWUO', 'Public', 'Config.ps1'), 'utf8');
  for (const [name, rule] of Object.entries(SETTINGS)) {
    assert.ok(ps.includes(name), `${name} missing from Config.ps1`);
    if (rule.type === 'int') {
      assert.match(ps, new RegExp(`${name}\\s*=\\s*@\\(${rule.min},\\s*${rule.max}\\)`), `${name} range differs from Config.ps1`);
      assert.match(ps, new RegExp(`${name}\\s*=\\s*${rule.def}\\b`), `${name} default differs from Config.ps1`);
    }
  }
  for (const m of MODES) assert.ok(ps.includes(`'${m}'`), `mode ${m}`);
});

test('base64 payloads round-trip, and a BOM is stripped', () => {
  const s = 'Write-Output "héllo"\n';
  assert.equal(Buffer.from(toBase64('﻿' + s), 'base64').toString('utf8'), s);
  assert.notEqual(Buffer.from(toBase64(s), 'base64')[0], 0xEF);
});

test('settings are validated', () => {
  assert.deepEqual(validateSettings({ FallbackGraceDays: 5, FixServices: 0 }), ['    FallbackGraceDays = 5', '    FixServices = 0']);
  assert.throws(() => validateSettings({ Nope: 1 }), /Unknown setting/);
  assert.throws(() => validateSettings({ MinFreeDiskGB: 9999 }), /between/);
  assert.throws(() => validateSettings({ FixPauses: 2 }), /0 or 1/);
  assert.throws(() => validateSettings({ FixPauses: 'x' }), /whole number/);
});

test('config scripts are stamped exactly like the build script does', async () => {
  const tpl = await readRepoFile('src/Config/Config.Remediate.template.ps1');
  const out = stampConfigScript(tpl, 'Remediate', { FallbackGraceDays: 4 });
  assert.match(out, /^\s{4}Mode = 'Remediate'$/m);
  assert.match(out, /^\s{4}FallbackGraceDays = 4$/m);
  assert.doesNotMatch(out, /__SETTINGS__/);
  assert.throws(() => stampConfigScript(tpl, 'Bogus'), /Unknown mode/);
});

test('assignment bodies: include groups run on the schedule, exclusions do not', () => {
  const b = assignmentBody(['g1', 'g2'], ['ex'], { '@odata.type': '#microsoft.graph.deviceHealthScriptHourlySchedule', interval: 8 });
  assert.equal(b.deviceHealthScriptAssignments.length, 3);
  assert.equal(b.deviceHealthScriptAssignments[0].target['@odata.type'], '#microsoft.graph.groupAssignmentTarget');
  assert.equal(b.deviceHealthScriptAssignments[0].runRemediationScript, true);
  assert.equal(b.deviceHealthScriptAssignments[2].target['@odata.type'], '#microsoft.graph.exclusionGroupAssignmentTarget');
  assert.equal(b.deviceHealthScriptAssignments[2].runRemediationScript, false);
});

test('config package requests: four packages, 64-bit SYSTEM, base64 scripts, only the start mode assigned', async () => {
  const reqs = await buildConfigPackageRequests({ modes: MODES, assignments: { ReportOnly: ['pilot'] } });
  assert.equal(reqs.length, 8);
  const creates = reqs.filter((r) => r.url.endsWith('/deviceHealthScripts'));
  assert.deepEqual(creates.map((r) => r.body.displayName), MODES.map((m) => `IntuneWUO-Config-${m}`));
  for (const c of creates) {
    assert.equal(c.body.runAsAccount, 'system');
    assert.equal(c.body.runAs32Bit, false);
    assert.equal(c.body.enforceSignatureCheck, false);
    assert.match(Buffer.from(c.body.remediationScriptContent, 'base64').toString('utf8'), /Mode = '/);
    assert.ok(c.saveResponseIdAs);
  }
  const assigns = reqs.filter((r) => r.url.endsWith('/assign'));
  assert.equal(assigns.find((r) => r.url.includes('ReportOnly')).body.deviceHealthScriptAssignments.length, 1);
  assert.equal(assigns.find((r) => r.url.includes('configScriptId_Off')).skipIfNoGroups, true);
});

test('remediation requests: the real scripts, 8-hour schedule, signature flag, schedule bounds', async () => {
  const reqs = await buildRemediationRequests({ includeGroupIds: ['pilot'], excludeGroupIds: ['ex'], enforceSignatureCheck: true });
  const detect = Buffer.from(reqs[0].body.detectionScriptContent, 'base64').toString('utf8');
  assert.match(detect, /Detect-WUO|Format-WUOStatus/);
  assert.equal(reqs[0].body.enforceSignatureCheck, true);
  assert.equal(reqs[1].body.deviceHealthScriptAssignments[0].runSchedule.interval, 8);
  assert.equal(reqs[1].body.deviceHealthScriptAssignments[0].runSchedule['@odata.type'], '#microsoft.graph.deviceHealthScriptHourlySchedule');
  await assert.rejects(() => buildRemediationRequests({ includeGroupIds: ['x'], intervalHours: 24 }), /1 to 23/);
});

test('mode change: needs current assignments first, then computes exact lists without dropping other groups', () => {
  const first = buildModeChange({ fromMode: 'ReportOnly', toMode: 'Remediate', groupIds: ['pilot'] });
  assert.equal(first.needsCurrentAssignments, true);
  assert.ok(first.requests.every((r) => r.method === 'GET'));

  const done = buildModeChange({ fromMode: 'ReportOnly', toMode: 'Remediate', groupIds: ['pilot'], current: { ReportOnly: ['pilot', 'ringA'], Remediate: ['old'] } });
  assert.equal(done.needsCurrentAssignments, false);
  const add = done.requests[0].body.deviceHealthScriptAssignments.map((a) => a.target.groupId).sort();
  const rem = done.requests[1].body.deviceHealthScriptAssignments.map((a) => a.target.groupId);
  assert.deepEqual(add, ['old', 'pilot']);
  assert.deepEqual(rem, ['ringA']);
  assert.match(done.requests[0].description, /Add/);   // target first, so a device is never without a package

  assert.throws(() => buildModeChange({ fromMode: 'Off', toMode: 'Off', groupIds: ['g'] }), /same/);
  assert.throws(() => buildModeChange({ fromMode: 'Off', toMode: 'ReportOnly', groupIds: [] }), /at least one/);
});

test('win32 reference never claims to upload content', () => {
  const r = buildWin32AppReference({ version: '2.0.0' });
  assert.match(r.note, /Metadata only/);
  assert.equal(r.graphMetadata.displayVersion, '2.0.0');
  assert.match(r.adminCenterSettings.installCommand, /Sysnative/);
});

// ---------------------------------------------------------------- plan + validation
test('plan has the phases in order, placeholders for missing group ids, and approval on every write', () => {
  const plan = buildPlan({ pilotGroup: { name: 'WUO-Pilot' }, ringGroups: [{ name: 'Test' }], excludedGroup: { name: 'WUO-Excluded' } });
  assert.deepEqual(plan.phases.map((p) => p.id), ['P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7']);
  assert.equal(plan.summary.needsGroupIds, true);
  assert.match(renderPlanMarkdown(plan), /group-id/);
  for (const p of plan.phases) for (const s of p.steps.filter((x) => x.kind === 'graph')) assert.equal(s.requiresApproval, true, s.id);
  assert.ok(plan.guardrailsForAgent.some((g) => /ActionsFeedUri/.test(g)));
  assert.ok(plan.guardrailsForAgent.some((g) => /explicit yes/.test(g)));
});

test('plan with all ids supplied does not ask for more, and hotpatch adds its step', () => {
  const plan = buildPlan({ pilotGroup: { id: 'p' }, ringGroups: [{ id: 'r' }], excludedGroup: { id: 'e' }, hotpatch: true, signed: true });
  assert.equal(plan.summary.needsGroupIds, false);
  assert.ok(plan.phases[0].steps.some((s) => s.id === 'P0.7'));
  assert.match(plan.phases[1].steps[0].commands.join(' '), /CertThumbprint/);
});

test('rollout stages never skip a stage and end with the fallback', () => {
  assert.deepEqual(ROLLOUT_STAGES.map((s) => s.mode), ['ReportOnly', 'Remediate', 'ReportOnly', 'Remediate', 'RemediateAndFallback']);
});

test('graph requests: scope selection, pilot-only first step, bad scope rejected', async () => {
  const all = await buildGraphRequests({ pilotGroupId: 'pilot', excludeGroupIds: ['ex'] });
  assert.equal(all.requests.length, 10);
  const cfgOnly = await buildGraphRequests({ scope: 'config', pilotGroupId: 'pilot', includeAllModes: false, startMode: 'ReportOnly' });
  assert.equal(cfgOnly.requests.length, 2);
  await assert.rejects(() => buildGraphRequests({ scope: 'weird' }), /scope must be/);
  assert.ok(all.requests.every((r) => r.writes === true && r.requiresPermission));
});

test('validation checklists exist for every phase and never print the signed Autopatch link', () => {
  for (const phase of Object.keys(PHASES)) assert.ok(validationChecklist(phase).checks.length >= 3, phase);
  assert.throws(() => validationChecklist('nope'), /Unknown phase/);
  // No command may read the signed link: look at the command text with trailing "# comments" removed.
  let warned = false;
  for (const checks of Object.values(PHASES)) {
    for (const c of checks) {
      const code = c.command.replace(/\s+#.*$/, '');
      assert.doesNotMatch(code, /ActionsFeedUri/, c.check);
      if (/WindowsAutopatch\\\\?ClientBroker/.test(code)) {
        warned = warned || /do NOT print ActionsFeedUri/.test(c.command);
        assert.match(code, /Select-Object\s+Ring/, 'broker key must be read with an explicit property list');
      }
    }
  }
  assert.ok(warned, 'the broker check must warn about ActionsFeedUri');
});
