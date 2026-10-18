# Deploy Intune-WUO with an AI agent

Use ChatGPT, Claude, Grok, Gemini, Copilot or any agent that supports MCP (or can simply read a web page) to plan and deploy Intune-WUO with natural language. This page tells an **agent** what to read and an **IT admin** how to connect everything safely.

- [What you get](#what-you-get)
- [Quick start (60 seconds)](#quick-start-60-seconds)
- [Connect your client](#connect-your-client)
- [Remote clients: ChatGPT and Grok](#remote-clients-chatgpt-and-grok)
- [Connect to your Intune tenant](#connect-to-your-intune-tenant)
- [What to ask](#what-to-ask)
- [Safety checklist](#safety-checklist)
- [Tools reference](#tools-reference)
- [Troubleshooting](#troubleshooting)

## What you get

| Piece | What it is | Where |
|---|---|---|
| **MCP server** | Teaches an agent the project and generates the deployment plan and exact Microsoft Graph request bodies. **Offline and read-only**: it never contacts your tenant and holds no credentials | `mcp/`, started with `npx -y github:bmrepository/Intune-WUOP` |
| **Skill** | The workflow, hard rules and Graph facts in one file, for Claude Code and any agent that loads skills | [`skills/intune-wuo-deploy/SKILL.md`](../skills/intune-wuo-deploy/SKILL.md) |
| **Claude Code plugin** | Skill + MCP server in one install | `/plugin install intune-wuo --marketplace bmrepository/Intune-WUOP` |
| **`AGENTS.md` and `llms.txt`** | Vendor-neutral entry points for agents that only read URLs | [`AGENTS.md`](../AGENTS.md), [`llms.txt`](../llms.txt) |
| **Graph executor** | Applies the generated requests from a terminal with a confirmation on every request | [`tools/Invoke-WUOGraphRequests.ps1`](../tools/Invoke-WUOGraphRequests.ps1) |

### The design in one sentence

**The knowledge and the keys are separate.** This server knows how to deploy Intune-WUO but has no access to anything. Your agent's own tenant tool (or you) holds the access, and a human approves each batch of changes. That is deliberate: you can install the server anywhere without granting it anything.

## Quick start (60 seconds)

1. Install [Node.js 22 or later](https://nodejs.org) (the server needs it; nothing else).
2. Add the server to your client (examples below). For Claude Code:

   ```bash
   claude mcp add intune-wuo -- npx -y github:bmrepository/Intune-WUOP
   ```

3. Ask your agent:

   > Use the Intune-WUO MCP server to help me deploy Intune-WUO to my tenant. I have Windows Enterprise E3, my devices are in Windows Autopatch, and I want to start with a pilot group.

   The agent calls `wuo_overview`, asks only what it needs, checks prerequisites, and walks you through the plan phase by phase. It will show you every tenant change and wait for your yes.

**No MCP in your client?** Paste this instead: *"Read https://raw.githubusercontent.com/bmrepository/Intune-WUOP/main/AGENTS.md and https://raw.githubusercontent.com/bmrepository/Intune-WUOP/main/docs/AI-AGENTS.md, then help me deploy Intune-WUO following the rules in them."*

> **Supply-chain note.** `npx github:...` runs code from the repository's default branch. To pin a release, use a tag: `npx -y github:bmrepository/Intune-WUOP#v0.1.0`. You can also `git clone`, review the `mcp/` folder (about 1,000 lines, no network calls except reading documents), run `npm install`, and start it with `node mcp/server.mjs`.

## Connect your client

All of these start the same stdio server. Replace nothing; the command is the same everywhere.

### Claude Code

```bash
# the server only
claude mcp add intune-wuo -- npx -y github:bmrepository/Intune-WUOP

# or the plugin (skill + server), Claude Code 2.1.275 or later
/plugin install intune-wuo --marketplace bmrepository/Intune-WUOP
# older versions:  /plugin marketplace add bmrepository/Intune-WUOP   then   /plugin install intune-wuo@intune-wuo

# or just the skill: copy skills/intune-wuo-deploy to ~/.claude/skills/ (all projects) or .claude/skills/ (this project)
```

If you cloned the repository, the root `.mcp.json` already declares the server; Claude Code asks you to approve it the first time.

### Claude Desktop

`claude_desktop_config.json` (Settings > Developer > Edit Config):

```json
{
  "mcpServers": {
    "intune-wuo": { "command": "npx", "args": ["-y", "github:bmrepository/Intune-WUOP"] }
  }
}
```

On Windows, if the app cannot find `npx`, use `"command": "cmd", "args": ["/c", "npx", "-y", "github:bmrepository/Intune-WUOP"]`.

### VS Code (GitHub Copilot agent mode)

`.vscode/mcp.json`:

```json
{
  "servers": {
    "intune-wuo": { "type": "stdio", "command": "npx", "args": ["-y", "github:bmrepository/Intune-WUOP"] }
  }
}
```

### Cursor

`.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (all projects):

```json
{
  "mcpServers": {
    "intune-wuo": { "command": "npx", "args": ["-y", "github:bmrepository/Intune-WUOP"] }
  }
}
```

### Gemini CLI

`~/.gemini/settings.json` (or `.gemini/settings.json` in a project):

```json
{
  "mcpServers": {
    "intune-wuo": { "command": "npx", "args": ["-y", "github:bmrepository/Intune-WUOP"] }
  }
}
```

Run `/mcp` inside Gemini CLI to confirm it connected.

### OpenAI Codex CLI

`~/.codex/config.toml`:

```toml
[mcp_servers.intune-wuo]
command = "npx"
args = ["-y", "github:bmrepository/Intune-WUOP"]
```

> The snippets for VS Code, Cursor, Codex and Claude Desktop follow each product's documented MCP configuration at the time of writing, but client config formats change. If a client rejects one, check its MCP documentation: the command to run is always `npx -y github:bmrepository/Intune-WUOP`.

## Remote clients: ChatGPT and Grok

ChatGPT custom connectors and the Grok API talk to a **remote HTTPS** MCP server, not a local process. This server has an HTTP mode for that:

```bash
node mcp/server.mjs --http --port 3333      # listens on http://127.0.0.1:3333/mcp (stateless, POST only)
```

Put it behind your own TLS reverse proxy (Caddy, nginx, Cloudflare Tunnel, Azure App Service, ...) to get `https://your-host/mcp`.

| Setting | Meaning |
|---|---|
| `WUO_MCP_TOKEN=<secret>` | Require `Authorization: Bearer <secret>`. **Mandatory** if you bind to anything other than loopback. |
| `WUO_ALLOW_UNAUTHENTICATED=1` | Deliberately allow a non-loopback listener with no token. Only for a public, read-only deployment (see below). |
| `--host`, `--port`, `PORT`, `HOST` | Where to listen. |
| `WUO_SOURCE=auto\|local\|github` | Where documents come from (default: the local clone, then GitHub). |

- **ChatGPT**: needs Developer mode and a custom connector (Settings > Connectors/Apps; the exact menu and the plans that include it vary, so check OpenAI's current help). The connector takes an HTTPS URL ending in `/mcp` and offers OAuth or no authentication.
- **Grok (xAI API)**: add the server to the request's `tools` with a `server_url` and a `server_label`; only Streamable HTTP and SSE are supported. See [xAI's Remote MCP Tools documentation](https://docs.x.ai/developers/tools/remote-mcp) for the current request shape. Grok also has custom connectors on grok.com on paid plans.

**Is it safe to host this publicly?** The server contains only public project documentation and pure generators. It has no credentials, makes no tenant calls and cannot change anything, so a public, unauthenticated deployment exposes nothing that is not already on GitHub. Still rate-limit it at the proxy, and prefer a bearer token wherever your client can send one. **Never** host a version of this server that you have given tenant credentials.

## Connect to your Intune tenant

The MCP server plans and generates. Something else has to *execute* the changes in your tenant. Pick the lowest level of access that gets the job done:

| Level | What the agent can do | How |
|---|---|---|
| **0. No access** (safest) | Plans, explains, generates the exact requests and admin-center steps. **You** click. | Nothing to set up |
| **1. Read-only** | Also verifies groups, existing packages, assignments and device status before you act | A read-only tenant tool, for example the [Microsoft MCP Server for Enterprise](https://learn.microsoft.com/graph/mcp-server/overview) (preview, read-only, Entra: users, groups, apps, devices) or a community read-only Intune/Entra MCP server such as EndpointRead-MCP |
| **2. Terminal, you sign in** (recommended for writes) | Executes the generated requests one at a time, each confirmed by you, as you | `tools/Invoke-WUOGraphRequests.ps1` with Microsoft Graph PowerShell and delegated sign-in |
| **3. Graph MCP with write access** | Executes the requests itself, after you approve each batch in the chat | A Graph-capable MCP server such as the community [Lokka](https://github.com/merill/lokka) (Graph beta by default), with a least-privilege app registration |

> We have not tested Intune-WUO with the third-party servers above; they are examples. Review any tenant-connected tool and its code before you grant it access, start in a test tenant, and treat level 3 as the highest-risk option.

### Recommended setup (level 2)

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# 1. Ask the agent to produce the requests (it saves them as requests.json)
# 2. Preview, nothing is sent and you are not even signed in:
.\tools\Invoke-WUOGraphRequests.ps1 -RequestsFile .\requests.json -WhatIf

# 3. Run for real: sign-in prompt, then every request is shown and needs your 'y'
.\tools\Invoke-WUOGraphRequests.ps1 -RequestsFile .\requests.json
```

If Windows says *running scripts is disabled on this system*, allow scripts for that window only with `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (or start it with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-WUOGraphRequests.ps1 -RequestsFile .\requests.json`). `-RequestsFile` is required.

The executor shows each request with script contents summarised (never dumped), substitutes ids returned by earlier responses, skips requests that have no groups yet, stops on the first error or the first 'no', and writes a log of the ids it created. Because you sign in as yourself, Intune's audit log records **you**, and Conditional Access, MFA and PIM apply as usual.

### Permissions (least privilege)

| Permission | Why | Needed? |
|---|---|---|
| `DeviceManagementScripts.ReadWrite.All` | Create and assign the Remediations (the four config packages and the Detect/Remediate package) | Yes, for writes |
| `Group.Read.All` | Resolve the pilot, ring and excluded groups | Yes |
| `DeviceManagementManagedDevices.Read.All` | Read device status | Optional |
| `DeviceManagementApps.ReadWrite.All` | Only if the agent also creates the Win32 app | Optional; the encrypted `.intunewin` upload is not covered by this server, so use the admin center or a Win32 upload tool |

Prefer **delegated** permissions (the agent acts as you) over application permissions. If you must use an app registration:

- use a **certificate**, not a client secret, and store it in a vault;
- restrict it with Conditional Access for workload identities and scope its Intune role with **scope tags**;
- consider a separate test tenant for the first run;
- remove the permissions or delete the registration when the rollout is finished;
- review **Intune > Tenant administration > Audit logs** afterwards.

The Intune health-script (Remediation) APIs are in the Graph **beta** endpoint, so they can change. Microsoft documents `deviceHealthScript` creation but marks the `assign` action's body as partly undocumented: check the first assignment in the admin center before you promote further.

### What the agent will do, in order

1. Ask what it needs and check prerequisites (licence, Autopatch, co-management, app control, access level).
2. Show the phased plan (P0 prepare, P1 build, P2 app, P3 config packages, P4 remediation, P5 observe, P6 roll out by ring, P7 operate).
3. Build the package on a Windows machine (`build/Build-IntuneWUO.ps1`) and, if you have a test device, run `tools/Invoke-WUOValidation.ps1`.
4. Create the four `IntuneWUO-Config-<Mode>` packages and the `IntuneWUO-DetectRemediate` Remediation, assigned to the **pilot only**, in **ReportOnly**.
5. After each phase, run the validation checks, and read device status lines back with `wuo_interpret_status`.
6. Promote one stage at a time. It will not skip stages.

## What to ask

- *"Deploy Intune-WUO to my tenant. Pilot group is `WUO-Pilot`, rings are `Autopatch-Test`, `-First`, `-Fast`, `-Broad`, exclude `WUO-Excluded`. I can sign in with Graph PowerShell."*
- *"Check whether my tenant is ready: Business Premium licences, devices in Autopatch, some co-managed."*
- *"Generate the Graph requests for the config packages, pilot only, ReportOnly."*
- *"Move the pilot from ReportOnly to Remediate."* (it reads current assignments first, because Graph's assign action replaces the whole list)
- *"Explain this device: `WUO|v1|NonCompliant|Mode=ReportOnly|Build=26100|Ring=Test|F=SVC_DISABLED_BITS,DISK_LOW`"*
- *"Kill switch: stop Intune-WUO on the Broad ring now."*
- *"What would roll this back?"*

## Safety checklist

- [ ] Start with a test tenant or the pilot group. Never All devices or All users.
- [ ] Every tenant write is shown to a human and approved per batch.
- [ ] The agent reads before it writes (group ids, existing `IntuneWUO-*` objects, current assignments).
- [ ] Each device receives exactly one `IntuneWUO-Config` package.
- [ ] `IntuneWUO-Config-Off` exists and is ready as the kill switch.
- [ ] No tokens, secrets or the Autopatch `ActionsFeedUri` value are pasted into chat, files or logs.
- [ ] The ids of everything created are recorded.
- [ ] Access is removed when the rollout is done.

## Tools reference

| Tool | Purpose |
|---|---|
| `wuo_overview` | What it is and does not do, modes, components, next tools |
| `wuo_check_prerequisites` | Blockers, warnings and recommendations from what is known about the tenant |
| `wuo_plan_deployment` | The phased plan, the rules for the agent, and markdown to show you |
| `wuo_generate_graph_requests` | Graph request bodies for the config packages and the Remediation (nothing is sent) |
| `wuo_generate_mode_change` | Move groups between modes safely (read current assignments first) |
| `wuo_win32_app_reference` | The Win32 app settings and reference metadata |
| `wuo_validation_checklist` | Commands and expected results for a phase (`install`, `reportonly`, `remediate`, `fallback`, `autopatch`) |
| `wuo_interpret_status` | Explain a `WUO|v1|...` device status line |
| `wuo_explain_finding`, `wuo_list_findings` | The findings catalogue |
| `wuo_get_doc` | Any project document or README section |

Also exposed: resources `wuo://docs/<name>` for the documents, and prompts `deploy_intune_wuo` and `troubleshoot_device`. Every tool is marked read-only.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Client says the server failed to start | Run `npx -y github:bmrepository/Intune-WUOP` in a terminal. Needs Node.js 22+ and network access to GitHub and npm the first time. |
| `npx` not found (Windows GUI apps) | Use `"command": "cmd", "args": ["/c", "npx", "-y", "github:bmrepository/Intune-WUOP"]`. |
| Corporate proxy blocks GitHub or npm | `git clone` the repository, run `npm install`, and start `node mcp/server.mjs`. |
| "Running scripts is disabled on this system" when running a `.ps1` | Windows' default execution policy. Use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (this window only) or `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`. |
| Tools list is empty | Restart the client; check its MCP log. |
| Documents not found | The server reads the local clone first, then GitHub. Set `WUO_SOURCE=github` to force GitHub. |
| HTTP: 401 | Send `Authorization: Bearer <WUO_MCP_TOKEN>`. |
| HTTP: server refuses to start | Non-loopback listeners need `WUO_MCP_TOKEN` (or the deliberate `WUO_ALLOW_UNAUTHENTICATED=1` for a public read-only deployment). |
| HTTP: 405 | The server is stateless: use `POST /mcp`. |
