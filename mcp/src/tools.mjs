// Registers the MCP tools, resources and prompts. All of them are offline and read-only.
import { z } from 'zod';
import { DOCS, SECTIONS, getDoc } from './content.mjs';
import { loadCatalogue, findFinding } from './catalogue.mjs';
import { parseStatusLine, interpretStatus } from './status.mjs';
import { checkPrerequisites } from './prerequisites.mjs';
import { buildPlan, buildGraphRequests, renderPlanMarkdown, guardrails, ROLLOUT_STAGES } from './plan.mjs';
import { buildModeChange, buildWin32AppReference, MODES, SETTINGS } from './payloads.mjs';
import { validationChecklist, PHASES } from './validation.mjs';

export const REPO_URL = 'https://github.com/bmrepository/Intune-WUOP';

export const SERVER_INSTRUCTIONS = `Intune-WUO is an open-source Windows Update orchestration layer for Intune-managed Windows devices that work with Windows Autopatch. This server teaches you the project and produces deployment plans and Microsoft Graph request bodies. It is offline and read-only: it never contacts a tenant and holds no credentials.

How to help a user deploy it:
1. Call wuo_overview, then wuo_check_prerequisites with whatever the user knows.
2. Call wuo_plan_deployment and walk the user through the phases in order.
3. For tenant changes use wuo_generate_graph_requests / wuo_generate_mode_change, then execute them with YOUR OWN Graph-capable tool, only after the human approves each batch. If you have no tenant tool, give the human the requests or the admin-center steps instead.
4. After each phase use wuo_validation_checklist. Paste device status lines into wuo_interpret_status.
Always start with the pilot group in ReportOnly. Never assign to all devices. Never read or repeat the Autopatch ActionsFeedUri value (it contains a signed token).`;

const text = (value) => ({ content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }] });
const failure = (error) => ({ isError: true, content: [{ type: 'text', text: `Error: ${error instanceof Error ? error.message : String(error)}` }] });
const guard = (fn) => async (args) => { try { return await fn(args ?? {}); } catch (e) { return failure(e); } };

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

const groupSchema = z.object({ name: z.string().optional(), id: z.string().optional() }).describe('An Entra device group. The id (object id GUID) is needed before any write.');

export function overview() {
  return {
    name: 'Intune-WUO: Intune Windows Update Orchestration Platform',
    repo: REPO_URL,
    whatItDoes: 'A self-healing layer that works alongside Windows Autopatch. It detects device-side problems that stop approved updates installing, fixes the safe ones automatically, and as a last resort installs overdue approved quality updates. It reports to Intune through Remediation output and to local logs.',
    neverDoes: ['restart a device', 'show UI to the user', 'change update or Autopatch policy', 'install drivers or feature updates', 'install anything Autopatch has not approved', 'change VBS or CHPE settings'],
    modes: { Off: 'Kill switch. Nothing runs.', ReportOnly: 'Default. Detect and report only.', Remediate: 'Detect, report and apply safe fixes.', RemediateAndFallback: 'Also installs overdue approved updates via a scheduled task.' },
    components: ['Win32 app (engine + scheduled task)', 'Remediation IntuneWUO-DetectRemediate (every 8 h, SYSTEM, 64-bit)', 'Four IntuneWUO-Config packages (one per mode; each device gets exactly one)'],
    requirements: ['Windows 11', 'Windows Autopatch registration (recommended)', 'Intune Remediations licence: Windows Enterprise E3/E5 or equivalent'],
    howAgentsHelp: {
      tools: ['wuo_check_prerequisites', 'wuo_plan_deployment', 'wuo_generate_graph_requests', 'wuo_generate_mode_change', 'wuo_win32_app_reference', 'wuo_validation_checklist', 'wuo_interpret_status', 'wuo_explain_finding', 'wuo_get_doc', 'wuo_list_findings'],
      safety: 'This server is offline and read-only. Tenant writes are done by the agent\'s own audited tool, after human approval.'
    },
    rolloutStages: ROLLOUT_STAGES.map((s) => `${s.stage}: ${s.groups} -> ${s.mode} (${s.wait})`),
    readNext: ['wuo_get_doc name=ai-agents', 'wuo_get_doc name=readme section=deployment-guide']
  };
}

export function registerAll(server) {
  server.registerTool('wuo_overview', {
    title: 'Intune-WUO overview',
    description: 'Start here. What Intune-WUO is, what it never does, its modes and components, and which tools to call next.',
    inputSchema: {},
    annotations: READ_ONLY
  }, guard(async () => text(overview())));

  server.registerTool('wuo_get_doc', {
    title: 'Read a project document',
    description: `Returns a project document (or one README section) from the local clone or GitHub. name: ${Object.keys(DOCS).join(' | ')}. section (README only): ${Object.keys(SECTIONS).join(' | ')}.`,
    inputSchema: { name: z.enum(Object.keys(DOCS)), section: z.string().optional().describe('A README section short name, or part of a heading') },
    annotations: { ...READ_ONLY, openWorldHint: true }
  }, guard(async ({ name, section }) => text(await getDoc(name, section))));

  server.registerTool('wuo_check_prerequisites', {
    title: 'Check deployment prerequisites',
    description: 'Given what is known about the tenant, returns blockers, warnings and recommendations. Unknown facts never block but are listed. Call before planning.',
    inputSchema: {
      windowsLicence: z.enum(['E3E5', 'BusinessPremium', 'Other', 'Unknown']).optional().describe('Windows licence covering the device users. Remediations need Enterprise E3/E5 or equivalent.'),
      autopatchEnrolled: z.boolean().optional(),
      clientBrokerDeployed: z.boolean().optional(),
      windows11: z.boolean().optional(),
      oldestWindowsBuild: z.number().int().optional().describe('Lowest OS build in scope, for example 26100'),
      coManaged: z.boolean().optional(),
      windowsUpdateWorkloadOnIntune: z.boolean().optional(),
      hybridOrGpo: z.boolean().optional(),
      wsusRemnants: z.boolean().optional(),
      appControl: z.enum(['none', 'wdac', 'applocker', 'both', 'unknown']).optional(),
      canSignScripts: z.boolean().optional(),
      graphAccess: z.enum(['none', 'read', 'write', 'unknown']).optional().describe('What the AI agent can do in the tenant'),
      pilotDevicesAvailable: z.boolean().optional(),
      testDeviceAvailable: z.boolean().optional(),
      hotpatchWanted: z.boolean().optional()
    },
    annotations: READ_ONLY
  }, guard(async (args) => text(checkPrerequisites(args))));

  server.registerTool('wuo_plan_deployment', {
    title: 'Plan the deployment',
    description: 'Returns the ordered, phased deployment plan (P0 prepare, P1 build, P2 app, P3 config packages, P4 remediation, P5 observe, P6 roll out by ring, P7 operate) with verification and exit criteria, plus the rules the agent must follow. Also returns markdown to show the human.',
    inputSchema: {
      pilotGroup: groupSchema.optional(),
      ringGroups: z.array(groupSchema).optional().describe('Autopatch ring groups in rollout order (Test, First, Fast, Broad)'),
      excludedGroup: groupSchema.optional(),
      version: z.string().regex(/^\d+\.\d+\.\d+$/).optional(),
      signed: z.boolean().optional().describe('Scripts will be signed and signature enforcement turned on'),
      hotpatch: z.boolean().optional(),
      graphAccess: z.enum(['none', 'read', 'write', 'unknown']).optional()
    },
    annotations: READ_ONLY
  }, guard(async (args) => { const plan = buildPlan(args); return text({ ...plan, markdown: renderPlanMarkdown(plan) }); }));

  server.registerTool('wuo_generate_graph_requests', {
    title: 'Generate Microsoft Graph requests',
    description: 'Builds the Graph (beta) request bodies that create and assign the IntuneWUO config packages and the DetectRemediate Remediation. NOTHING is sent. Review with the human, then execute with your own tenant tool, in order, substituting saved ids for {placeholders}.',
    inputSchema: {
      scope: z.enum(['config', 'remediation', 'all']).optional(),
      pilotGroupId: z.string().optional(),
      ringGroupIds: z.array(z.string()).optional().describe('Extra groups for the Remediation assignment (leave empty for the pilot-only first step)'),
      excludeGroupIds: z.array(z.string()).optional(),
      startMode: z.enum(MODES).optional().describe('Mode the pilot starts in. Default ReportOnly.'),
      includeAllModes: z.boolean().optional().describe('Create all four config packages up front (default true) so mode changes and the kill switch are ready'),
      settings: z.record(z.number().int()).optional().describe(`Optional extra settings to stamp into every config package: ${Object.keys(SETTINGS).join(', ')}`),
      signed: z.boolean().optional().describe('Set enforceSignatureCheck on the Remediation (use scriptsDir with signed scripts)'),
      scriptsDir: z.string().optional().describe('Local folder with built (for example signed) Detect-WUO.ps1 / Remediate-WUO.ps1. Only works when the server runs on the machine that has the folder.'),
      version: z.string().regex(/^\d+\.\d+\.\d+$/).optional()
    },
    annotations: READ_ONLY
  }, guard(async (args) => text(await buildGraphRequests(args))));

  server.registerTool('wuo_generate_mode_change', {
    title: 'Move groups between modes',
    description: 'Computes the Graph requests that move device groups from one mode package to another (for example ReportOnly -> Remediate). Graph\'s assign action replaces a package\'s whole assignment list, so first call without currentAssignments to get the read requests, then call again with the group ids you read.',
    inputSchema: {
      fromMode: z.enum(MODES), toMode: z.enum(MODES),
      groupIds: z.array(z.string()).min(1),
      currentAssignments: z.record(z.array(z.string())).optional().describe('Map of mode -> group ids currently assigned, for both modes involved'),
      excludeGroupIds: z.array(z.string()).optional()
    },
    annotations: READ_ONLY
  }, guard(async ({ fromMode, toMode, groupIds, currentAssignments, excludeGroupIds }) => text(buildModeChange({ fromMode, toMode, groupIds, current: currentAssignments, excludeGroupIds }))));

  server.registerTool('wuo_win32_app_reference', {
    title: 'Win32 app settings',
    description: 'The settings (and reference Graph metadata) for the Intune-WUO Win32 app. The encrypted .intunewin upload itself is not handled here: use the admin center or a Win32 upload tool.',
    inputSchema: { version: z.string().optional() },
    annotations: READ_ONLY
  }, guard(async ({ version }) => text(buildWin32AppReference({ version }))));

  server.registerTool('wuo_validation_checklist', {
    title: 'Validation checks for a phase',
    description: `Commands and expected results to verify a phase on a device or in Intune. phase: ${Object.keys(PHASES).join(' | ')}.`,
    inputSchema: { phase: z.enum(Object.keys(PHASES)) },
    annotations: READ_ONLY
  }, guard(async ({ phase }) => text(validationChecklist(phase))));

  server.registerTool('wuo_interpret_status', {
    title: 'Interpret a device status line',
    description: 'Parses the one-line status Intune-WUO reports in Remediation output (starts with WUO|v1|) and explains each finding, what the tool does about it, and what an administrator should do.',
    inputSchema: { statusLine: z.string().describe('For example: WUO|v1|NonCompliant|Mode=ReportOnly|Build=26100|Ring=Test|F=SVC_DISABLED_BITS,DISK_LOW') },
    annotations: READ_ONLY
  }, guard(async ({ statusLine }) => text(interpretStatus(parseStatusLine(statusLine), await loadCatalogue()))));

  server.registerTool('wuo_explain_finding', {
    title: 'Explain one finding id',
    description: 'Looks up a finding id (for example POLICY_CONFLICT_NOAUTOUPDATE) in the catalogue.',
    inputSchema: { id: z.string() },
    annotations: READ_ONLY
  }, guard(async ({ id }) => {
    const f = findFinding(await loadCatalogue(), id);
    if (!f) throw new Error(`Unknown finding id '${id}'. Use wuo_list_findings.`);
    return text(f);
  }));

  server.registerTool('wuo_list_findings', {
    title: 'List all finding ids',
    description: 'Every finding id with severity and whether Intune-WUO can fix it automatically.',
    inputSchema: {},
    annotations: READ_ONLY
  }, guard(async () => {
    const c = await loadCatalogue();
    return text(c.findings.map((f) => ({ id: f.id, severity: f.severity, autoFix: f.autoFix, title: f.title })));
  }));

  // Resources: the same documents, for clients that prefer to attach them.
  for (const [name, entry] of Object.entries(DOCS)) {
    server.registerResource(`doc-${name}`, `wuo://docs/${name}`, {
      title: entry.file, description: entry.description,
      mimeType: name === 'findings' ? 'application/json' : 'text/markdown'
    }, async (uri) => ({ contents: [{ uri: uri.href, mimeType: name === 'findings' ? 'application/json' : 'text/markdown', text: await getDoc(name) }] }));
  }

  // Prompts: ready-made conversation starters.
  server.registerPrompt('deploy_intune_wuo', {
    title: 'Deploy Intune-WUO to my tenant',
    description: 'Guided deployment: prerequisites, plan, build, pilot in ReportOnly, then ring-by-ring rollout.',
    argsSchema: { tenantNotes: z.string().optional().describe('Anything you already know: licences, groups, co-management, app control') }
  }, ({ tenantNotes }) => ({
    messages: [{ role: 'user', content: { type: 'text', text:
      `Help me deploy Intune-WUO (${REPO_URL}) to my Intune tenant.\n\nWhat I know: ${tenantNotes || 'nothing yet, please ask me.'}\n\nFollow this order: call wuo_overview; ask me only for facts you need and call wuo_check_prerequisites; call wuo_plan_deployment and show me the plan; then go phase by phase. Use wuo_generate_graph_requests for tenant changes and show me each batch before you send anything. Start with the pilot group in ReportOnly. Rules:\n- ${guardrails().join('\n- ')}` } }]
  }));

  server.registerPrompt('troubleshoot_device', {
    title: 'Explain an Intune-WUO status line',
    description: 'Explain a device status line and say what to do next.',
    argsSchema: { statusLine: z.string().describe('The WUO|v1|... line from Intune Remediation output') }
  }, ({ statusLine }) => ({
    messages: [{ role: 'user', content: { type: 'text', text: `Use wuo_interpret_status on this Intune-WUO status line, then tell me in plain language what is wrong and the exact next steps:\n\n${statusLine}` } }]
  }));
}
