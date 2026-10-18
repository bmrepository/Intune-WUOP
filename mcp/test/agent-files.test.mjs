import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { REPO_ROOT } from '../src/content.mjs';

const read = (rel) => readFile(path.join(REPO_ROOT, rel), 'utf8').then((t) => t.replace(/\r\n/g, '\n'));
const exists = (rel) => existsSync(path.join(REPO_ROOT, rel));
const RAW = 'https://raw.githubusercontent.com/bmrepository/Intune-WUOP/main/';
const BLOB = 'https://github.com/bmrepository/Intune-WUOP/tree/main/';

test('SKILL.md has valid frontmatter, matches its folder, stays short, and carries the hard rules', async () => {
  const text = await read('skills/intune-wuo-deploy/SKILL.md');
  assert.ok(text.startsWith('---\n'), 'frontmatter must be the first line');
  const fm = /^---\n([\s\S]*?)\n---\n/.exec(text);
  assert.ok(fm, 'frontmatter must be closed');
  assert.match(fm[1], /^name: intune-wuo-deploy$/m);
  const desc = /^description: (.+)$/m.exec(fm[1])?.[1] ?? '';
  assert.ok(desc.length > 100, 'description needs to say what and when');
  const when = /^when_to_use: (.+)$/m.exec(fm[1])?.[1] ?? '';
  assert.ok(desc.length + when.length <= 1536, 'description + when_to_use are truncated at 1,536 characters');
  assert.ok(text.split('\n').length < 500, 'keep SKILL.md under 500 lines');
  for (const rule of [/pilot/i, /ReportOnly/, /ActionsFeedUri/, /replaces the whole assignment list/i, /explicit yes/i, /Never assign to All devices/i, /exactly one/i]) {
    assert.match(text, rule, `rule missing: ${rule}`);
  }
  // Every MCP tool the skill names must really exist.
  const { registerAll } = await import('../src/tools.mjs');
  const names = [];
  registerAll({ registerTool: (n) => names.push(n), registerResource() {}, registerPrompt() {} });
  for (const m of text.matchAll(/`(wuo_[a-z_]+)`/g)) assert.ok(names.includes(m[1]), `skill mentions unknown tool ${m[1]}`);
});

test('AGENTS.md and llms.txt only point at files that exist', async () => {
  const agents = await read('AGENTS.md');
  for (const m of agents.matchAll(/\]\(([^)#]+?)\)/g)) {
    if (/^https?:/.test(m[1])) continue;
    assert.ok(exists(m[1]), `AGENTS.md links to missing ${m[1]}`);
  }
  const llms = await read('llms.txt');
  assert.match(llms, /^# Intune-WUO$/m);
  assert.match(llms, /^> /m);
  for (const m of llms.matchAll(/\]\((https:[^)]+)\)/g)) {
    const url = m[1];
    const rel = url.startsWith(RAW) ? url.slice(RAW.length) : url.startsWith(BLOB) ? url.slice(BLOB.length) : null;
    assert.ok(rel !== null, `llms.txt link is not a project URL: ${url}`);
    assert.ok(exists(rel), `llms.txt links to a file that does not exist: ${rel}`);
  }
});

test('every relative link in docs/AI-AGENTS.md exists', async () => {
  const text = await read('docs/AI-AGENTS.md');
  for (const m of text.matchAll(/\]\((\.\.?\/[^)#]+?)\)/g)) {
    assert.ok(exists(path.posix.normalize(path.posix.join('docs', m[1]))), `missing ${m[1]}`);
  }
});

test('plugin, marketplace and .mcp.json agree with each other and with package.json', async () => {
  const plugin = JSON.parse(await read('.claude-plugin/plugin.json'));
  const market = JSON.parse(await read('.claude-plugin/marketplace.json'));
  const mcp = JSON.parse(await read('.mcp.json'));
  const pkg = JSON.parse(await read('package.json'));
  assert.equal(market.plugins[0].name, plugin.name, 'entry name must equal the manifest name');
  assert.equal(plugin.version, pkg.version, 'plugin and package versions should match');
  assert.deepEqual(mcp.mcpServers['intune-wuo'].args, ['-y', 'github:bmrepository/Intune-WUOP']);
  assert.equal(pkg.bin['intune-wuo-mcp'], 'mcp/server.mjs');
  assert.ok(exists(pkg.bin['intune-wuo-mcp']));
  assert.match(await read(pkg.bin['intune-wuo-mcp']), /^#!\/usr\/bin\/env node/);
  assert.ok(exists('skills/intune-wuo-deploy/SKILL.md'));
});

test('the documented npx command in every doc is the one .mcp.json uses', async () => {
  const cmd = 'npx -y github:bmrepository/Intune-WUOP';
  for (const f of ['README.md', 'AGENTS.md', 'docs/AI-AGENTS.md', 'skills/intune-wuo-deploy/SKILL.md', 'llms.txt']) {
    assert.ok((await read(f)).includes(cmd), `${f} should show: ${cmd}`);
  }
});

test('nothing in the agent-facing files could hand an agent the signed Autopatch link', async () => {
  for (const f of ['AGENTS.md', 'llms.txt', 'docs/AI-AGENTS.md', 'skills/intune-wuo-deploy/SKILL.md', 'README.md', 'docs/DESIGN.md']) {
    const text = await read(f);
    assert.doesNotMatch(text, /sig=[A-Za-z0-9%]{20,}/, `${f} contains something that looks like a SAS signature`);
    assert.doesNotMatch(text, /skoid=|sktid=/, `${f} contains SAS query parameters`);
    for (const line of text.split('\n')) {
      if (/ActionsFeedUri/.test(line)) assert.match(line, /never|not|do not|don't|Never|NOT|deliberately|carries|contains|signed|token/i, `${f}: ActionsFeedUri mentioned without a warning: ${line.slice(0, 100)}`);
    }
  }
});
