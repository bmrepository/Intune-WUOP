// Parses and explains the one-line status that Intune-WUO prints for Intune Remediations.
// Formats (see docs/DESIGN.md, "Reporting"):
//   WUO|v1|<Compliant|NonCompliant|Disabled>|Mode=<m>|Build=<n>[|Ring=<r>][|F=<id>,<id>[+N]]
//   WUO|v1|Remediated|Fixed=<ids>|Failed=<ids>|Suppressed=<ids>
//   WUO|v1|NoAction|Mode=<m>      WUO|v1|NoAction|Busy      WUO|v1|Error|<message>
import { findFinding } from './catalogue.mjs';

const splitIds = (v) => (v ? v.split(',').map((s) => s.trim()).filter(Boolean) : []);

export function parseStatusLine(line) {
  const text = String(line ?? '').trim();
  const parts = text.split('|');
  if (parts[0] !== 'WUO' || parts.length < 3) {
    throw new Error("Not an Intune-WUO status line. Expected it to start with 'WUO|v1|'.");
  }
  const out = { raw: text, version: parts[1], result: parts[2], fields: {}, notes: [], findings: [], overflow: 0, fixed: [], failed: [], suppressed: [] };

  if (out.result === 'Error') {
    out.error = parts.slice(3).join('|');
    return out;
  }
  for (const token of parts.slice(3)) {
    const eq = token.indexOf('=');
    if (eq === -1) { out.notes.push(token); continue; }
    out.fields[token.slice(0, eq)] = token.slice(eq + 1);
  }
  if (out.fields.F) {
    const m = /^(.*?)(?:\+(\d+))?$/.exec(out.fields.F);
    out.findings = splitIds(m[1]);
    out.overflow = m[2] ? Number(m[2]) : 0;
  }
  out.fixed = splitIds(out.fields.Fixed);
  out.failed = splitIds(out.fields.Failed);
  out.suppressed = splitIds(out.fields.Suppressed);
  out.mode = out.fields.Mode;
  out.build = out.fields.Build ? Number(out.fields.Build) : undefined;
  out.ring = out.fields.Ring;
  return out;
}

export function interpretStatus(parsed, catalogue) {
  const explain = (id) => {
    const f = findFinding(catalogue, id);
    return f
      ? { id: f.id, severity: f.severity, autoFix: f.autoFix, title: f.title, cause: f.cause, toolAction: f.toolAction, adminAction: f.adminAction }
      : { id, severity: 'Unknown', autoFix: 'Unknown', title: 'Not in the catalogue', cause: 'This id is newer than the catalogue the agent is using, or it is mistyped.', toolAction: '', adminAction: 'Update the project (git pull) and check docs/findings.json.' };
  };

  const summary = { result: parsed.result, mode: parsed.mode, build: parsed.build, ring: parsed.ring };
  const next = [];

  if (parsed.result === 'Error') {
    return { summary, explanation: `The Intune-WUO script failed on the device: ${parsed.error}`, findings: [], nextSteps: ['Open C:\\ProgramData\\Microsoft\\IntuneManagementExtension\\Logs\\IntuneWUO\\IntuneWUO.jsonl on the device (or collect diagnostics from Intune) and look at the Error entries.', 'Detection errors never trigger remediation, so the device is unchanged.'] };
  }
  if (parsed.result === 'Disabled') {
    return { summary, explanation: 'Mode is Off on this device (the kill switch). Nothing is detected or changed.', findings: [], nextSteps: ['If this is unexpected, check which IntuneWUO-Config package the device receives. Each device must receive exactly one.'] };
  }
  if (parsed.result === 'NoAction') {
    const why = parsed.notes.includes('Busy') ? 'another Intune-WUO run held the lock' : `mode is ${parsed.mode ?? 'not a remediation mode'}`;
    return { summary, explanation: `The remediation script did nothing because ${why}.`, findings: [], nextSteps: [] };
  }
  if (parsed.result === 'Remediated') {
    const fixed = parsed.fixed.map(explain);
    const failed = parsed.failed.map(explain);
    const suppressed = parsed.suppressed.map(explain);
    if (failed.length) next.push('Fixes that failed need a person: see each finding\'s adminAction. WaaSMedicSvc is protected by Windows and is expected to fail.');
    if (suppressed.length) next.push('Suppressed fixes were being undone by something else (policy, baseline or another tool). Find that source; Intune-WUO stops re-applying after FixMaxRepeats.');
    return { summary: { ...summary, fixed: parsed.fixed.length, failed: parsed.failed.length, suppressed: parsed.suppressed.length }, explanation: `Remediation applied ${fixed.length} fix(es); ${failed.length} failed; ${suppressed.length} suppressed.`, fixed, failed, suppressed, findings: [], nextSteps: next };
  }

  const findings = parsed.findings.map(explain);
  const critical = findings.filter((f) => f.severity === 'Critical');
  const warning = findings.filter((f) => f.severity === 'Warning');
  const info = findings.filter((f) => f.severity === 'Info');
  const fixable = findings.filter((f) => f.autoFix !== 'None' && f.autoFix !== 'Unknown');
  summary.counts = { critical: critical.length, warning: warning.length, info: info.length, notListed: parsed.overflow };

  if (parsed.result === 'Compliant') {
    return { summary, explanation: info.length ? `Compliant. ${info.length} informational note(s) only.` : 'Compliant. No findings.', findings, nextSteps: [] };
  }

  if (critical.length) next.push(`Fix the ${critical.length} Critical finding(s) first: ${critical.map((f) => f.id).join(', ')}.`);
  if (fixable.length && parsed.mode === 'ReportOnly') next.push(`Mode is ReportOnly, so nothing was changed. ${fixable.length} finding(s) are auto-fixable (${fixable.map((f) => f.id).join(', ')}); once a ring has had a clean ReportOnly cycle, move it to Remediate.`);
  if (fixable.length && (parsed.mode === 'Remediate' || parsed.mode === 'RemediateAndFallback')) next.push('These are auto-fixable; the next Remediation run (every 8 hours) will apply them. If they persist, check for repeated-fix suppression.');
  const reportOnly = findings.filter((f) => f.autoFix === 'None' && f.severity !== 'Info');
  if (reportOnly.length) next.push(`Report-only findings need an administrator: ${reportOnly.map((f) => f.id).join(', ')}.`);
  if (parsed.overflow > 0) next.push(`${parsed.overflow} more finding(s) did not fit in the 2,048-character status line. Read IntuneWUO.jsonl on the device for the full list.`);

  return { summary, explanation: `NonCompliant: ${critical.length} Critical, ${warning.length} Warning, ${info.length} Info finding(s).`, findings, nextSteps: next };
}
