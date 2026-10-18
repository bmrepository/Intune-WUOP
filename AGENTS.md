# Instructions for AI agents (vendor-neutral)

This repository is **Intune-WUO**, an open-source Windows Update orchestration layer for Intune-managed Windows devices that use Windows Autopatch. These instructions are for any agent (ChatGPT, Claude, Grok, Gemini, Copilot, Codex and others).

## If a user asks you to deploy or operate it

1. **Connect the MCP server** if your client supports MCP (offline, read-only, no credentials):
   - stdio clients (Claude Code, Claude Desktop, Cursor, VS Code, Gemini CLI, Codex CLI): `npx -y github:bmrepository/Intune-WUOP`
   - remote clients (ChatGPT, Grok API): run `node mcp/server.mjs --http` behind HTTPS. See [docs/AI-AGENTS.md](docs/AI-AGENTS.md).
2. **Or read the docs** in this order if you cannot use MCP: [docs/AI-AGENTS.md](docs/AI-AGENTS.md), then the README sections *Modes and switches*, *Prerequisites*, *Deployment guide*, then [docs/findings.json](docs/findings.json). A machine-friendly index is in [llms.txt](llms.txt).
3. **Load the skill** if you are Claude Code: [skills/intune-wuo-deploy/SKILL.md](skills/intune-wuo-deploy/SKILL.md) (or install the plugin: `/plugin install intune-wuo --marketplace bmrepository/Intune-WUOP`).

## Continuing development

If you are taking over development (for example while another assistant is unavailable), read **[HANDOFF.md](HANDOFF.md)** first: current state, decisions already made, a prioritised backlog, gotchas, and the definition of done.

## Non-negotiable rules

- Start with a **pilot group in ReportOnly**. Never assign to All devices or All users.
- **Never write to a tenant without the human approving the exact batch of changes.** If you have no tenant access, give the human the plan and the requests.
- Graph's `assign` action **replaces** the whole assignment list: read current assignments first.
- Each device receives **exactly one** `IntuneWUO-Config-<Mode>` package.
- **Never read, print or log the Autopatch `ActionsFeedUri`** registry value (signed access token). Never handle tokens or secrets in chat or logs.
- Do not change update policy, Autopatch policy, VBS or CHPE: Intune-WUO reports those and leaves them to Intune policy.
- Do not invent setting names, finding ids or Graph bodies. Take them from the docs, `docs/findings.json` or the MCP tools.

## If you are working on the code

- Layout: `src/IntuneWUO` (PowerShell module), `src/Remediation`, `src/Win32`, `src/Config`, `build/`, `tools/`, `tests/` (Pester 5+), `mcp/` (Node MCP server and its tests), `docs/`, `skills/`.
- Tests: `Invoke-Pester -Path .\tests` (PowerShell) and `npm test` (Node 22+).
- PowerShell scripts that Intune runs must be **ASCII only, UTF-8 without BOM, Windows PowerShell 5.1 compatible**, and must not use `$PSScriptRoot` in param-block defaults.
- `docs/findings.json` must list exactly the ids in `src/IntuneWUO/Public/Events.ps1` (a Pester test enforces it). `mcp/src/payloads.mjs` must stay in sync with `src/IntuneWUO/Public/Config.ps1` (a Node test enforces it).
- Be honest about what is proven: see the Roadmap in the README and `docs/DESIGN.md` section 11.
