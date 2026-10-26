import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { startHttp } from '../server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.resolve(here, '..', 'server.mjs');

const EXPECTED_TOOLS = [
  'wuo_overview', 'wuo_get_doc', 'wuo_check_prerequisites', 'wuo_plan_deployment', 'wuo_generate_graph_requests',
  'wuo_generate_mode_change', 'wuo_win32_app_reference', 'wuo_validation_checklist', 'wuo_interpret_status',
  'wuo_explain_finding', 'wuo_list_findings', 'wuo_package_requests'
];

async function exercise(client) {
  const tools = (await client.listTools()).tools;
  const names = tools.map((t) => t.name).sort();
  assert.deepEqual(names, [...EXPECTED_TOOLS].sort());
  for (const t of tools) {
    assert.ok(t.description && t.description.length > 20, `${t.name} needs a real description`);
    assert.equal(t.annotations?.readOnlyHint, true, `${t.name} must be marked read-only`);
  }

  const status = await client.callTool({ name: 'wuo_interpret_status', arguments: { statusLine: 'WUO|v1|NonCompliant|Mode=ReportOnly|Build=26100|Ring=Test|F=SVC_DISABLED_BITS' } });
  assert.ok(!status.isError);
  const parsed = JSON.parse(status.content[0].text);
  assert.equal(parsed.findings[0].id, 'SVC_DISABLED_BITS');

  const bad = await client.callTool({ name: 'wuo_interpret_status', arguments: { statusLine: 'nonsense' } });
  assert.equal(bad.isError, true);

  const plan = await client.callTool({ name: 'wuo_plan_deployment', arguments: { pilotGroup: { name: 'Pilot' } } });
  assert.match(JSON.parse(plan.content[0].text).markdown, /Rules for the agent/);

  const req = await client.callTool({ name: 'wuo_generate_graph_requests', arguments: { pilotGroupId: 'pilot-id', scope: 'remediation' } });
  const body = JSON.parse(req.content[0].text);
  assert.equal(body.requests[0].method, 'POST');
  assert.match(body.requests[0].url, /graph\.microsoft\.com\/beta\/deviceManagement\/deviceHealthScripts$/);

  const invalid = await client.callTool({ name: 'wuo_get_doc', arguments: { name: 'readme', section: 'definitely-not-a-section' } });
  assert.equal(invalid.isError, true);

  const resources = (await client.listResources()).resources.map((r) => r.uri);
  assert.ok(resources.includes('wuo://docs/readme'));
  const doc = await client.readResource({ uri: 'wuo://docs/findings' });
  assert.ok(JSON.parse(doc.contents[0].text).findings.length > 20);

  const prompts = (await client.listPrompts()).prompts.map((p) => p.name).sort();
  assert.deepEqual(prompts, ['deploy_intune_wuo', 'troubleshoot_device']);
  const p = await client.getPrompt({ name: 'troubleshoot_device', arguments: { statusLine: 'WUO|v1|Compliant|Mode=ReportOnly|Build=1' } });
  assert.match(p.messages[0].content.text, /wuo_interpret_status/);

  assert.match(client.getInstructions() ?? '', /offline and read-only/);
}

test('stdio: the real server process speaks MCP and every tool is read-only', async () => {
  const client = new Client({ name: 'test', version: '0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [serverPath], env: { ...process.env, WUO_SOURCE: 'local' } });
  await client.connect(transport);
  try { await exercise(client); } finally { await client.close(); }
});

test('http: stateless Streamable HTTP works, with and without a bearer token', async () => {
  const server = await startHttp({ host: '127.0.0.1', port: 0, token: 'secret-token' });
  const { port } = server.address();
  try {
    // no token -> 401
    const denied = await fetch(`http://127.0.0.1:${port}/mcp`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.equal(denied.status, 401);
    // wrong method -> 405
    const wrong = await fetch(`http://127.0.0.1:${port}/mcp`, { method: 'GET', headers: { authorization: 'Bearer secret-token' } });
    assert.equal(wrong.status, 405);
    // health needs no token
    assert.equal((await fetch(`http://127.0.0.1:${port}/health`)).status, 200);
    // unknown path
    assert.equal((await fetch(`http://127.0.0.1:${port}/other`)).status, 404);

    const client = new Client({ name: 'test', version: '0' });
    const transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), { requestInit: { headers: { authorization: 'Bearer secret-token' } } });
    await client.connect(transport);
    try { await exercise(client); } finally { await client.close(); }
  } finally {
    await new Promise((r) => server.close(r));
  }
});

test('http: refuses to listen on a non-loopback address without a token', async () => {
  await assert.rejects(() => startHttp({ host: '0.0.0.0', port: 0, token: undefined }), /WUO_MCP_TOKEN/);
});

test('http: the public read-only override must be explicit', async () => {
  const prev = process.env.WUO_ALLOW_UNAUTHENTICATED;
  process.env.WUO_ALLOW_UNAUTHENTICATED = '1';
  const server = await startHttp({ host: '0.0.0.0', port: 0, token: undefined });
  try {
    const { port } = server.address();
    assert.equal((await fetch(`http://127.0.0.1:${port}/health`)).status, 200);
  } finally {
    await new Promise((r) => server.close(r));
    if (prev === undefined) delete process.env.WUO_ALLOW_UNAUTHENTICATED; else process.env.WUO_ALLOW_UNAUTHENTICATED = prev;
  }
});
