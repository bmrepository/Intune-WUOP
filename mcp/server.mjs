#!/usr/bin/env node
// Intune-WUO MCP server. Offline and read-only: it never contacts a tenant and holds no credentials.
//
//   node server.mjs                        stdio (Claude Code, Claude Desktop, Cursor, VS Code, Gemini CLI, ...)
//   node server.mjs --http [--port 3333]   Streamable HTTP on http://127.0.0.1:3333/mcp (ChatGPT / Grok connectors
//                                          need an HTTPS URL, so put this behind your own TLS reverse proxy)
//
//   WUO_SOURCE=auto|local|github   where project documents come from (default: local clone, then GitHub)
//   WUO_MCP_TOKEN=<secret>         require "Authorization: Bearer <secret>" on HTTP (mandatory if not on loopback)
//   WUO_ALLOW_UNAUTHENTICATED=1    deliberately allow a non-loopback listener with no token (public, read-only deployments only)
import http from 'node:http';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { registerAll, SERVER_INSTRUCTIONS } from './src/tools.mjs';

export function createServer() {
  const server = new McpServer({ name: 'intune-wuo', version: '1.0.0' }, { instructions: SERVER_INSTRUCTIONS });
  registerAll(server);
  return server;
}

function parseArgs(argv) {
  const o = { http: false, port: Number(process.env.PORT ?? 3333), host: process.env.HOST ?? '127.0.0.1' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--http') o.http = true;
    else if (argv[i] === '--port') o.port = Number(argv[++i]);
    else if (argv[i] === '--host') o.host = argv[++i];
  }
  return o;
}

const isLoopback = (h) => ['127.0.0.1', 'localhost', '::1'].includes(h);

export async function startHttp({ host, port, token = process.env.WUO_MCP_TOKEN }) {
  if (!isLoopback(host) && !token && process.env.WUO_ALLOW_UNAUTHENTICATED !== '1') {
    throw new Error('Refusing to listen on a non-loopback address without WUO_MCP_TOKEN. Set a bearer token and put TLS in front of it, or set WUO_ALLOW_UNAUTHENTICATED=1 for a deliberately public, read-only deployment.');
  }
  const httpServer = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
      if (url.pathname === '/health') { res.writeHead(200, { 'content-type': 'text/plain' }).end('ok'); return; }
      if (url.pathname !== '/mcp') { res.writeHead(404).end('Not found'); return; }
      if (token && req.headers.authorization !== `Bearer ${token}`) { res.writeHead(401, { 'www-authenticate': 'Bearer' }).end('Unauthorized'); return; }
      if (req.method !== 'POST') { res.writeHead(405, { allow: 'POST' }).end('Stateless server: use POST'); return; }

      const chunks = [];
      for await (const c of req) chunks.push(c);
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : undefined;

      // Stateless: a fresh server and transport per request. Nothing is shared between callers.
      const server = createServer();
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on('close', () => { transport.close(); server.close(); });
      await server.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (e) {
      if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32603, message: String(e.message ?? e) }, id: null }));
    }
  });
  await new Promise((resolve) => httpServer.listen(port, host, resolve));
  return httpServer;
}

const invokedDirectly = (() => {
  try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
})();
if (invokedDirectly) {
  const args = parseArgs(process.argv.slice(2));
  if (args.http) {
    const s = await startHttp(args);
    const a = s.address();
    console.error(`Intune-WUO MCP server (HTTP) listening on http://${a.address}:${a.port}/mcp`);
  } else {
    await createServer().connect(new StdioServerTransport());
    console.error('Intune-WUO MCP server (stdio) ready');
  }
}
