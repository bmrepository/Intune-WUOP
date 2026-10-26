// Loads project documents and scripts. Local clone first, GitHub raw as a fallback.
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(here, '..', '..');
export const DEFAULT_REMOTE_BASE = 'https://raw.githubusercontent.com/bmrepository/Intune-WUOP/main/';
const remoteBase = () => process.env.WUO_REMOTE_BASE ?? DEFAULT_REMOTE_BASE;

const remoteCache = new Map();

function normalise(text) {
  return text.replace(/^﻿/, '').replace(/\r\n/g, '\n');
}

/**
 * Read a text file that belongs to the project (path relative to the repo root, forward slashes).
 * WUO_SOURCE: "auto" (default: local clone, then GitHub), "local", or "github".
 */
export async function readRepoFile(rel, { source = process.env.WUO_SOURCE ?? 'auto', root = REPO_ROOT } = {}) {
  if (rel.includes('..')) throw new Error(`Refusing path outside the project: ${rel}`);
  const local = path.join(root, ...rel.split('/'));
  if (source !== 'github' && existsSync(local)) return normalise(await readFile(local, 'utf8'));
  if (source === 'local') throw new Error(`File not found in the local clone: ${rel}`);

  const url = remoteBase() + rel;
  if (remoteCache.has(url)) return remoteCache.get(url);
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`Could not read ${rel} from ${url}: HTTP ${res.status}`);
  const text = normalise(await res.text());
  remoteCache.set(url, text);
  return text;
}

/** Document names exposed to agents. */
export const DOCS = {
  readme: { file: 'README.md', description: 'Project README: what it is, settings, registry reference, deployment guide.' },
  design: { file: 'docs/DESIGN.md', description: 'Design: components, finding catalogue, guardrails, fallback rules, event ids.' },
  'ai-agents': { file: 'docs/AI-AGENTS.md', description: 'How AI agents connect to this project and to a tenant.' },
  agents: { file: 'AGENTS.md', description: 'Short, vendor-neutral instructions for AI agents.' },
  findings: { file: 'docs/findings.json', description: 'Machine-readable catalogue of every finding id.' },
  skill: { file: 'skills/intune-wuo-deploy/SKILL.md', description: 'The deployment skill (Claude Code skill format).' }
};

/** README sections an agent can ask for by short name. */
export const SECTIONS = {
  architecture: 'What it does',
  'quick-start': 'Quick start',
  'how-it-works': 'How a run works',
  'checks-and-fixes': 'What it checks and fixes',
  hotpatch: 'Hotpatch',
  modes: 'Settings',
  settings: 'Settings',
  'registry-reference': 'Registry and CSP reference',
  prerequisites: 'Prerequisites',
  'deployment-guide': 'Deployment guide',
  operating: 'Operating it',
  security: 'Security model',
  'win32-edition': 'Optional: the Win32 app edition',
  roadmap: 'Roadmap'
};

/** Returns the markdown section whose heading contains `heading` (case-insensitive), up to the next heading of the same or higher level. */
export function extractSection(markdown, heading) {
  const lines = markdown.split('\n');
  const want = heading.toLowerCase();
  let start = -1;
  let level = 0;
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^```/.test(lines[i])) inFence = !inFence;
    if (inFence) continue;
    const m = /^(#{1,6})\s+(.*)$/.exec(lines[i]);
    if (!m) continue;
    if (start === -1) {
      if (m[2].toLowerCase().includes(want)) { start = i; level = m[1].length; }
    } else if (m[1].length <= level) {
      return lines.slice(start, i).join('\n').trimEnd();
    }
  }
  return start === -1 ? null : lines.slice(start).join('\n').trimEnd();
}

export async function getDoc(name, section) {
  const entry = DOCS[name];
  if (!entry) throw new Error(`Unknown document '${name}'. Available: ${Object.keys(DOCS).join(', ')}`);
  const text = await readRepoFile(entry.file);
  if (!section) return text;
  const heading = SECTIONS[section] ?? section;
  const out = extractSection(text, heading);
  if (out === null) throw new Error(`Section '${section}' not found in ${name}. Known README sections: ${Object.keys(SECTIONS).join(', ')}`);
  return out;
}
