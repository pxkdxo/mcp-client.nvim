---
title: MCP Hub Neovim Client - Plan
type: feat
date: 2026-07-17
topic: mcp-hub-neovim-client
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# MCP Hub Neovim Client - Plan

## Goal Capsule

- **Objective:** replace `mcphub.nvim` and its patched `ravitemer/mcp-hub` daemon with `mcp-client`, a from-scratch, LSP-inspired MCP client core plus thin Avante and CodeCompanion adapters, reaching full functional parity and proven hub-agnosticism before any cutover.
- **Product authority:** this Product Contract; the Planning Contract and Implementation Units below implement it without altering its scope.
- **Execution profile:** software implementation plan, `execution: code`. U1-U9 target this repo (`mcp-client`); U10 (cutover) targets the dotfiles repo (`~/.local/etc`).
- **Stop conditions:** if contact with a real hub or the MCP spec proves a settled decision infeasible, surface it rather than silently reworking scope. Do not begin U10 until U1-U9's Definition of Done is met.
- **Tail ownership:** the executing session owns running tests, fixing failures, and committing per unit; this plan does not choreograph exact commands.
- **Open blockers:** none — the three questions the requirements doc deferred to planning (orchestrator porting, native-server API shape, parity checklist) are all resolved below.

---

## Product Contract

### Summary

Build `mcp-client`: a shareable, from-scratch Neovim MCP client with an LSP-inspired core and thin Avante/CodeCompanion adapters. It fully replaces `mcphub.nvim`'s tool-bridging and native-server-hosting role, talks only the standard MCP protocol endpoint (no hub-proprietary API), and must reach full functional parity with `mcphub.nvim` and prove hub-agnosticism against a second real hub before cutover.

### Problem Frame

`mcphub.nvim`'s daemon depends on `ravitemer/mcp-hub`, whose `main` branch has stagnated (last commit `9c7670a`, 2025-08-22, v4.2.1; 21 open PRs, several dependabot bumps unmerged 6-12+ months). A recursive-close bug in `src/mcp/server.js#handleSSEConnection` — the same cleanup callback registered on both `res.on("close")` and `transport.onclose`, so `server.close()` re-triggers itself until V8 throws `RangeError` — crashes the daemon whenever Cursor (re)connects via `~/.cursor/mcp.json`. The fix (`ravitemer/mcp-hub#140`) has sat open since 2026-05-02 with no review activity. The workaround, `scripts/mcphub-launch.sh` (dotfiles repo), patches `dist/cli.js` with a re-entrancy guard on every launch, because `mcphub.nvim`'s build step (`npm install -g mcp-hub@latest`) reverts the patch each time.

Swapping hub implementations alone would not remove the client-side coupling: neither editor plugin can reach a remote hub without an intermediary. Avante has no native MCP client as of July 2026 — it only gets MCP access through `mcphub.nvim`'s extension. CodeCompanion's native MCP client is stdio-only, spawning local server subprocesses per buffer with no Streamable HTTP/SSE support, so it isn't a path to hub-agnosticism either. `mcphub.nvim` also couples both integrations to its own proprietary `/api/*` management surface (`/api/health`, `/api/servers`, `/api/workspaces`, `/api/marketplace`), separate from the standards-compliant MCP tool-call path (`GET /mcp` → `POST /messages`).

### Key Decisions

- **Full replacement, one push, no incremental cutover** (session-settled: user-directed — chosen over an Avante-first incremental cutover and a standalone-core-first checkpoint: the user wants core, both adapters, native-server hosting, generic config, docs, and second-hub validation built before `ai.lua` switches over, rather than a staged rollout or an early personal-use checkpoint).
- **Rewrite from scratch with an LSP-inspired core** (session-settled: user-directed — chosen over upstreaming into `mcphub.nvim` or forking and stripping it: a core modeled on `vim.lsp` avoids inheriting hidden `mcp-hub`-specific assumptions, such as workspace-isolation semantics and `/api/*` coupling, that a fork would carry inside borrowed code).
- **Built shareable from the start** (session-settled: user-directed — chosen over personal-use-only: config is generic and documented with no hardcoded personal paths, ports, or credentials, and the plugin carries a real README so it could eventually be published).
- **Hub-agnosticism proven against `samanhappy/mcphub` specifically** (session-settled: user-directed — chosen over a hand-written stub server: the second-hub validation target is a real, independently-maintained MCP hub implementation, not one authored to already fit this client).
- **No dashboard/health-panel UI** (session-settled: user-directed — chosen over rebuilding a minimal `:MCPHub`-style panel: the interactive dashboard isn't used day-to-day, so parity targets the functional tool-bridging and native-server surface; status is exposed via a `:checkhealth`-style command or logs instead).
- **Native-server hosting ships as a general core capability; porting `orchestrator.lua` itself is not assumed** (session-settled: user-directed — corrects an initial assumption that porting `orchestrator.lua` was included by default; that file was auto-generated rather than deliberately designed, so whether to rebuild, redesign, or drop its specific tool set is an open design call for planning, not inherited from `mcphub.nvim`'s current shape).
- **Repo name `mcphub-neovim` kept for now** (session-settled: user-directed — chosen over renaming immediately: naming doesn't block the spec; revisit before any public release given the similarity to `mcphub.nvim`). **Superseded 2026-07-20:** renamed to `mcp-client.nvim` (require namespace `mcp-client`) — the "hub" framing was itself found to be a slight misnomer (the client works identically against a multiplexing hub or a plain standalone MCP server; nothing in the protocol path is hub-specific), so `hubs`/`connect_hub`/etc. terminology was generalized to `servers`/`connect_server`/etc. throughout at the same time.

### Requirements

**Core MCP client**

- R1. The core connects to a remote MCP hub over the standard Streamable HTTP/SSE MCP protocol endpoint only — no dependency on any hub's proprietary management API (e.g. `mcphub.nvim`'s `/api/*` surface).
- R2. The core exposes hub and server state through Neovim-native primitives modeled on `vim.lsp` — autocmds/`User` events for state changes and a `get_clients()`-style query API — rather than a bespoke event bus.
- R3. The core supports registering native, in-process Lua-defined MCP servers (local tool/resource/prompt providers) alongside remote hub connections, as a general capability independent of any specific server implementation.

**Editor adapters**

- R4. An Avante adapter exposes MCP tools, resources (vars), and prompts (slash commands) to Avante as a thin consumer of the core's public API, replacing `mcphub.extensions.avante`.
- R5. A CodeCompanion adapter provides equivalent tool/resource/prompt bridging for CodeCompanion chat, replacing `mcphub.extensions.codecompanion`.
- R6. Neither adapter talks to a hub or native server directly — both consume only the core's Neovim-native API.

**Packaging and shareability**

- R7. All configuration (hub URL, server list, native servers, adapter options) is externally supplied — no hardcoded personal paths, ports, or credentials in the plugin's source.
- R8. The plugin ships with documentation (README/config reference) sufficient for someone other than the author to install and configure it, including the native-server trust model (native servers run with full Neovim/Lua privilege, equivalent to trusted first-party code; no sandboxing is provided) and hub authentication expectations.

**Validation**

- R9. Before cutover, the plugin is validated end-to-end against both `ravitemer/mcp-hub` (the current daemon) and `samanhappy/mcphub` (the verification reference) to demonstrate hub-agnosticism.
- R10. The plugin reaches full functional parity with `mcphub.nvim`'s current tool-bridging and native-server-hosting surface (per `nvim/lua/plugins/ai.lua`, dotfiles repo) before `ai.lua` is switched over to it. Parity excludes `orchestrator.lua`'s specific tool set, per the Key Technical Decisions below, which resolve the planning decision this requirement originally deferred: orchestrator.lua is not ported for v1, so the conditional symmetric-exposure clause across the Avante and CodeCompanion adapters — and its dependency on the `make_vars` gap in Dependencies / Assumptions being fixed upstream — does not apply unless a future follow-up plan revisits porting it.

**Resilience and security**

- R11. The core detects hub connection loss or errors and surfaces them through the same Neovim-native state/event API as R2; adapters (R4/R5) degrade gracefully — a visible failure, not a hang — rather than assuming the connection is always healthy.
- R12. The client supports standard authentication (e.g. a bearer token) and transport security (TLS) for hub connections that are not on localhost — needed because the plugin is built shareable from the start (R7/R8) and a third-party adopter's hub may not be localhost. The client refuses (fails closed) a non-localhost connection that lacks configured authentication or TLS, rather than warning and proceeding unauthenticated.

### Actors

- A1. Neovim user — invokes MCP tools, resources, and prompts from Avante or CodeCompanion chat.
- A2. Editor adapter (Avante adapter / CodeCompanion adapter) — thin consumers that translate the core's API into each plugin's tool/resource/prompt registration.
- A3. MCP client core — the LSP-inspired core managing hub connections and native-server registrations, exposing Neovim-native state and events.
- A4. Remote MCP hub — `ravitemer/mcp-hub` today, and `samanhappy/mcphub` as the second validation target; an external process fronting configured MCP servers over the standard protocol endpoint.
- A5. Native in-process server — a Lua-defined MCP server hosted directly by the core, no external process (e.g. a possible future orchestrator-equivalent).

### Key Flows

- F1. Tool invocation via chat
  - **Trigger:** user invokes a registered MCP tool, resource, or prompt from an Avante or CodeCompanion chat buffer.
  - **Actors:** A1, A2, A3, A4/A5
  - **Steps:** the adapter calls the core's public API; the core routes the call to the appropriate remote hub connection or native server; the response returns through the core to the adapter and renders in the chat buffer.
  - **Outcome:** the tool result appears in the chat conversation, with the adapter carrying no knowledge of which hub or native server served it.
- F2. Hub-agnosticism validation
  - **Trigger:** before cutover, the plugin is pointed at each of two different hub backends in turn.
  - **Actors:** A3, A4 (`ravitemer/mcp-hub`, then `samanhappy/mcphub`)
  - **Steps:** the core connects to the first hub and exercises its full tool/resource/prompt surface through both adapters; the process repeats unmodified against the second hub.
  - **Outcome:** identical adapter-facing behavior against both hubs, with no hub-specific code path in the core or adapters.
- F3. Native server registration
  - **Trigger:** the core starts with one or more native servers configured.
  - **Actors:** A3, A5
  - **Steps:** the core loads each native server definition and exposes its tools/resources/prompts through the same Neovim-native API used for remote hub servers.
  - **Outcome:** native-server tools are available to Avante/CodeCompanion identically to hub-provided tools.

### Success Criteria

- Full functional parity with `mcphub.nvim`'s tool-bridging and native-server-hosting surface, confirmed before `ai.lua` (dotfiles repo) cuts over to the new plugin.
- Hub-agnosticism demonstrated by working, unmodified, against both `ravitemer/mcp-hub` and `samanhappy/mcphub` — not merely assumed from protocol-only design. The proof includes reproducing the reconnect scenario that triggers `ravitemer/mcp-hub`'s SSE re-entrancy bug (R11), including the case where the daemon crashes mid-connection rather than closing cleanly, and confirming the core neither hangs nor crashes either way; hub-agnosticism is falsified by any adapter-visible behavioral divergence between the two hubs not attributable to documented protocol optionality.
- R12 is validated by pointing the client at a non-localhost (or TLS-fronted) hub with no credentials configured and confirming the connection is refused, and separately confirming a bearer-token/TLS-configured non-localhost hub connects successfully.
- Config and docs are usable by someone without access to the author's personal machine (no hardcoded paths, ports, or secrets).

### Scope Boundaries

**Deferred for later**

- Whether and how to port `orchestrator.lua`'s specific task-orchestration tools (`create_plan`, `get_next_subtask`, `complete_subtask`, `fail_subtask`, `get_plan_status`, `list_plans`, the `active_plans` resource, and the `orchestrate` prompt) as a native server — resolved for v1 during planning (see Key Technical Decisions); may be revisited as a follow-up plan.
- Renaming the repo away from `mcphub-neovim` — revisit before any public release. **Done 2026-07-20**, see the superseded Key Decision above.

**Outside this product's identity**

- Support for Neovim AI chat plugins other than Avante and CodeCompanion.
- Building or hosting an MCP hub server — this is a client only.
- An interactive dashboard/health-panel UI (`:MCPHub`-style server list, start/stop, logs) — status surfaces via a `:checkhealth`-style command or logs instead.
- Direct client-side stdio MCP server spawning (bypassing a hub) — resolved during planning; see Key Technical Decisions.

### Dependencies / Assumptions

- Assumes `ravitemer/mcp-hub`'s stagnation continues; the live patch in `scripts/mcphub-launch.sh` (dotfiles repo) stays in place as a stopgap until cutover.
- Assumes Avante's and CodeCompanion's current extension mechanisms (`custom_tools`/`system_prompt` hooks for Avante; the `extensions` mechanism for CodeCompanion) remain stable enough to build thin adapters against — noting `ai.lua` already documents one existing gap in this surface (`make_vars = false` for CodeCompanion's resource/var bridging, marked broken).
- Assumes `samanhappy/mcphub`, as an actively maintained implementation, exposes a standards-compliant MCP endpoint sufficient for validation — not yet verified against this project. If validation surfaces a protocol gap, the core is amended to close it or cutover is delayed; partial or mocked validation is not an acceptable substitute. Validation against both hubs uses non-sensitive or scoped third-party servers, not the full production credential set.

### Sources / Research

- `ravitemer/mcp-hub` — last commit `9c7670a` (2025-08-22, v4.2.1); 21 open PRs; PR #140 ("fix SSE cleanup") opened 2026-05-02, no review activity since.
- Re-entrancy bug: `src/mcp/server.js#handleSSEConnection` registers the same cleanup callback on `res.on("close")` and `transport.onclose`; `server.close()` → `transport.close()` → `res.end()` → refires `"close"` → recurses until V8 throws `RangeError`.
- `scripts/mcphub-launch.sh` (dotfiles repo) — live workaround patching `dist/cli.js` with an idempotent re-entrancy guard on every launch.
- `nvim/lua/plugins/ai.lua` (dotfiles repo) — current `mcphub.nvim` config: `server_url = "http://localhost:37373"`, `native_servers.orchestrator`, `extensions.avante`, `extensions.codecompanion`.
- `nvim/lua/servers/orchestrator.lua` (dotfiles repo) — task-orchestrator native server referenced in the native-server-hosting decision.
- Protocol surface split: the tool-call path is standard MCP over SSE (`GET /mcp` → `POST /messages`, no custom auth); `/api/*` is `mcp-hub`-proprietary and out of scope for the new core.
- MCP Streamable HTTP transport spec (2025-11-25 current, 2025-03-26 prior): single endpoint supporting GET+POST, replacing the 2024-11-05 two-endpoint (`GET /sse` + `POST /messages`) transport, which remains a sanctioned fallback with a documented client-side detection algorithm.
- MCP session management: `MCP-Session-Id`/`Mcp-Session-Id` header, `MCP-Protocol-Version` header, 404-on-dead-session triggers client reinitialization, DELETE for client-initiated termination.
- MCP reference TypeScript SDK (`packages/client/src/client/streamableHttp.ts`): default reconnection backoff (1000ms initial, 30000ms cap, 1.5x growth, honors server `retry:` hint, 2 max attempts by default); distinguishes intentional client abort from any other stream-end.
- MCP spec and SEP-1335: the protocol does not distinguish a hub crash from a clean server-initiated close at the transport layer — an acknowledged, open spec gap, not a design omission here.
- MCP Authorization spec (2025-06-18): OAuth 2.1 baseline is MUST-level (Protected Resource Metadata discovery RFC 9728, Authorization Server Metadata RFC 8414, PKCE, Resource Indicators RFC 8707, Bearer token per request); Dynamic Client Registration (RFC 7591) is SHOULD-level, with a documented hardcoded/manual-entry fallback when unsupported.
- Neovim `vim.lsp.Client` (local Neovim 0.12 runtime, `lua/vim/lsp/client.lua`): `id`/`name`/`config`/`is_stopped()`, `request(method, params, handler, bufnr)` with `(err, result, context)` handler signature, `notify()`, `LspAttach`/`LspDetach`/`LspNotify` autocmds firing with `data.client_id`, `on_exit(code, signal, client_id)`.
- Dotfiles repo Neovim plugin conventions: single-file `lua/plugins/*.lua` specs for consumption, multi-file `lua/<name>/init.lua` module layout for owned code; no existing custom `health.lua` in the user's own config (bundled plugins like `telescope.nvim` provide the reference pattern).

---

## Planning Contract

**Product Contract preservation:** Product Contract unchanged from the requirements-only version — all R/A/F IDs and Key Decisions are carried forward verbatim. The three items the requirements doc deferred to planning (Outstanding Questions: orchestrator porting, native-server API shape, parity checklist) are resolved below and folded into Scope Boundaries / Key Technical Decisions / the U9 parity checklist, so the standalone Outstanding Questions section is removed rather than left as an empty placeholder.

### Key Technical Decisions

- **LSP-inspired core, modeled directly on `vim.lsp` client idioms** (session-settled: user-directed — see Key Decisions, "Rewrite from scratch with an LSP-inspired core"). Concretely: mirror `vim.lsp.Client`'s shape (`id`, `name`, `config`, `is_stopped()`, `request(method, params, handler, bufnr)` with an `(err, result, context)` handler signature, `notify(method, params, bufnr)`) and the `LspAttach`/`LspDetach`/`LspNotify` autocmd pattern (custom `User` autocmds — `MCPAttach`/`MCPDetach`/`MCPNotify` — firing with `data = {client_id = ...}`), plus a `get_clients(filter)` query API mirroring `vim.lsp.get_clients()`. Grounds R2's commitment in Neovim's actual runtime idioms rather than an invented analogy.
- **Dual transport support: the modern single-endpoint Streamable HTTP transport, with the legacy two-endpoint HTTP+SSE transport as a spec-sanctioned detected fallback** (session-settled: user-approved — surfaced as a call-out, chosen over modern-transport-only). Required because neither `ravitemer/mcp-hub` nor `samanhappy/mcphub` is confirmed to have adopted the newest spec revision, and R9 requires validating against both with no hub-specific code path.
- **Session management follows the spec's `MCP-Session-Id`/`Mcp-Session-Id` header contract** — session ID echoed on every request after initialize, a 404 response means reinitialize, `MCP-Protocol-Version` sent on requests after initialize (defaulting to `2025-03-26` when a legacy server omits it). Unlabeled — a direct reading of the transport spec.
- **Reconnection: bounded exponential backoff modeled on the MCP reference TypeScript SDK's own defaults** (session-settled: user-approved — surfaced as a call-out). Initial delay 1000ms, cap 30000ms, 1.5x growth, honoring a server-sent SSE `retry:` hint over the computed delay, small bounded attempt count before surfacing a hard disconnected state. The MCP spec does not define retry timing (an acknowledged gap — SEP-1335); the reference SDK's values are the closest ecosystem convention.
- **The core cannot reliably distinguish "hub crashed" from "hub cleanly closed the connection"** — a stated MCP spec limitation (SEP-1335), not a gap in this design: a bare stream-read error and a deliberate server-initiated close look identical at the transport layer. R11's design goal is "detect any disconnection and surface it visibly, with bounded reconnection" — not "identify the cause." Unlabeled — a direct spec-grounded fact.
- **Native-server registration API: a config table per server (name plus capability tables for tools/resources/prompts, each entry a plain Lua function), passed at core setup** (session-settled: user-approved — surfaced as a call-out). Styled after `mcphub.nvim`'s existing `native_servers` table shape (familiar migration path), but registered servers are exposed through the same client/event API as remote ones so adapters cannot tell local from remote (satisfies F3). Resolves the native-server registration API question the requirements doc deferred to planning.
- **v1 auth is the MCP spec's full OAuth 2.1 flow, including Dynamic Client Registration (RFC 7591)** (session-settled: user-directed — chosen over a static/hardcoded bearer token: DCR lets the plugin register itself against whichever authorization server a user's hub happens to use, which a hardcoded or manually-entered client ID cannot do without per-deployment friction, and the plugin is built shareable from the start). Concretely: Protected Resource Metadata discovery (RFC 9728, triggered by a 401 + `WWW-Authenticate`), Authorization Server Metadata discovery (RFC 8414), Dynamic Client Registration (RFC 7591) when the AS supports it — falling back to a hardcoded or user-entered client ID per the spec's own documented fallback when it doesn't — Authorization Code grant with mandatory PKCE, a loopback (`localhost`) redirect listener paired with the system's browser-open command, the mandatory `resource` parameter (RFC 8707) binding the token to the specific hub, and a `Authorization: Bearer <token>` header on every subsequent request. Public-client refresh-token rotation (spec-mandated) applies since this plugin has no client secret.
- **No direct client-side stdio MCP server spawning** (session-settled: user-directed — chosen over adding a third connection mode). Everything routes through a hub (dual Streamable HTTP transport) or in-process native servers; matches the brainstorm's rejection of stdio-per-buffer-spawn (CodeCompanion's existing approach) as "not a path to hub-agnosticism."
- **`orchestrator.lua` is not ported for v1** (session-settled: user-directed — inherited from the Product Contract's "Native-server hosting ships as a general core capability; porting `orchestrator.lua` itself is not assumed," and confirmed directly during this planning session over porting it as-is or redesigned). R3 ships with no bundled native servers in v1; proven only via a minimal test-only example server.
- **Test framework: `plenary.nvim` busted-style specs**, run headless via a `make test` target. Unlabeled — the de facto Neovim plugin testing convention, and already a transitive dependency through `mcphub.nvim`/other plugins in the dotfiles config.
- **Formatting/linting: `stylua`** for Lua formatting, matching the ecosystem convention used by comparable Neovim plugins. Unlabeled, low-stakes tooling choice.
- **All hub/authorization-server network I/O — one-shot requests and the persistent SSE stream alike — is built on `plenary.curl` (already a planned dependency), never hand-rolled over raw `vim.uv` sockets.** Unlabeled — a build-vs-use correction grounded in a hard constraint: `vim.uv`/`luv` (libuv underneath it) has no TLS implementation at all, a long-standing, explicitly unaddressed upstream gap, so a TLS-secured persistent connection (required by R12 for non-localhost hubs) cannot be safely built on raw `vim.uv` sockets. Every comparable shipped Neovim plugin reaches the same conclusion — `avante.nvim`'s own LLM response streaming uses `plenary.curl` throughout, and `mcphub.nvim` itself hands all networking to an external Node.js process rather than attempt it in Lua. Streaming uses `plenary.curl`'s `stream` option (wired to `plenary.job`'s genuinely incremental `on_stdout`, backed by libuv's async `uv_read_start`) with an explicit `-N`/`--no-buffer` flag, holding one long-lived curl process open per stream, not a process per message. `vim.uv` is used directly for exactly one thing: the OAuth loopback redirect listener (U6), which is inherently plaintext-localhost-only by design (RFC 8252) and so has no TLS requirement to begin with.
- **Reconnect logic distinguishes an intentional close from a real disconnection via a caller-set flag on the streaming `Job` object (`job.user_data.intentional_close`), not by interpreting curl's exit code or signal.** Unlabeled — a correctness fix grounded in a verified gap: `plenary.curl`'s own internal exit handler drops the process's exit signal entirely, making "we killed it" and "it exited cleanly on its own" indistinguishable through that path alone. Before killing a stream's curl process for any deliberate reason (a fresh reconnect, an explicit user disconnect), the flag is set first, then `vim.uv.kill(job:pid(), "sigterm")` is called directly — `Job:shutdown()` alone only closes pipes and does not guarantee the OS process is dead. The stream's own exit handler, attached via `job:add_on_exit_callback` (not `plenary.curl`'s internal `on_exit`), checks the flag first: if set, no reconnect fires; otherwise both a clean exit and a curl network-error exit trigger the bounded-backoff reconnect (R11), since a clean server-initiated close and a hub crash are already established as indistinguishable and irrelevant to distinguish.

### System-Wide Impact

Both of the dotfiles repo's AI-chat surfaces (Avante and CodeCompanion) switch their MCP tool-bridging simultaneously at cutover (U10) — there is no partial-adapter rollout. The `mcphub.nvim`-specific launchd daemon and its patch script are decommissioned once cutover is confirmed, removing that operational surface entirely. This plan introduces a new credential-storage surface (OAuth tokens for non-localhost hubs) that did not exist in `mcphub.nvim`'s localhost-only usage.

### Risks & Dependencies

- The OAuth flow (U6/U7) may not be exercisable end-to-end against either reference hub during U9's validation, since both `ravitemer/mcp-hub` and `samanhappy/mcphub` are conventionally run on `localhost`, where R12 does not require auth. Mitigation: validate the OAuth path against a synthetic non-localhost test double in U9, and treat the two reference hubs as covering the transport/session/reconnect/parity surface rather than the auth surface.
- `samanhappy/mcphub`'s standards compliance is unverified until U9 runs; per Dependencies/Assumptions, a discovered gap is closed in the core or cutover is delayed, never worked around with partial/mocked validation.

---

## Implementation Units

### Unit Index

| U-ID | Title | Files touched | Depends on |
|---|---|---|---|
| U1 | Core scaffold & dual-transport connection | `lua/mcp-client/init.lua`, `lua/mcp-client/transport/*.lua` | — |
| U2 | Session lifecycle, reconnection & event API | `lua/mcp-client/client.lua`, `lua/mcp-client/session.lua`, `lua/mcp-client/reconnect.lua` | U1 |
| U3 | Native in-process server registration | `lua/mcp-client/native.lua` | U2 |
| U4 | Avante adapter | `lua/mcp-client/adapters/avante.lua` | U2, U3 |
| U5 | CodeCompanion adapter | `lua/mcp-client/adapters/codecompanion.lua` | U2, U3 |
| U6 | OAuth discovery & authorization flow | `lua/mcp-client/auth/*.lua` | U1 |
| U7 | Token management & fail-closed transport security | `lua/mcp-client/auth/*.lua`, `lua/mcp-client/transport/tls.lua` | U6 |
| U8 | Configuration, documentation, health check | `lua/mcp-client/config.lua`, `lua/mcp-client/health.lua`, `README.md` | U1-U7 |
| U9 | Hub-agnosticism & parity validation | `tests/integration/*.lua` | U1-U8 |
| U11 | Avante prompt/slash-command bridging | `lua/mcp-client/adapters/avante.lua` | U3, U4 |
| U12 | CodeCompanion prompt/slash-command bridging | `lua/mcp-client/adapters/codecompanion.lua` | U3, U5 |
| U10 | Cutover (dotfiles repo) | `nvim/lua/plugins/ai.lua` (dotfiles repo) | U1-U9, U11, U12 (all Definition of Done, not just U9's own unit) |

U6 and U7 both touch `lua/mcp-client/auth/`, on disjoint files: U6 owns `discovery.lua`/`dcr.lua`/`pkce.lua`/`redirect_listener.lua`; U7 owns `token_store.lua`/`refresh.lua`.

### U1. Core scaffold & dual-transport connection

- **Goal:** establish the plugin skeleton and connect the core to a remote MCP hub, supporting both the modern single-endpoint Streamable HTTP transport and the legacy two-endpoint HTTP+SSE fallback via the spec's detection algorithm.
- **Requirements:** R1
- **Dependencies:** none
- **Files:** `lua/mcp-client/init.lua`, `lua/mcp-client/transport/streamable_http.lua`, `lua/mcp-client/transport/legacy_sse.lua`, `lua/mcp-client/transport/detect.lua`, `tests/transport/detect_spec.lua`, `tests/transport/streamable_http_spec.lua`
- **Approach:** as an early step within this unit — before fully building the legacy-transport fallback — verify which transport version each reference hub (`ravitemer/mcp-hub`, `samanhappy/mcphub`) actually serves, so the fallback's necessity is confirmed early rather than discovered only at U9. On connect, POST an `InitializeRequest` to the configured hub URL; on success, use the modern single-endpoint transport for all subsequent requests. On a 400/404/405 response, fall back to legacy discovery (GET expecting an `endpoint` SSE event) and use the two-endpoint transport instead. Wrap both behind a common transport interface so the rest of the core is transport-agnostic. The GET request for either transport's SSE stream is made via `plenary.curl` with `raw = {"-N"}` (disabling curl's buffering) and a `stream` callback for incremental delivery, holding one curl process open for the life of the connection — never re-invoked per message. Expose the module as `require("mcp-client")`, not `require("mcphub")`, to avoid colliding with `mcphub.nvim`'s own module name while both may be present during development, before cutover (U10).
- **Patterns to follow:** `vim.lsp.start()`'s config/opts split as the rough shape for the core's own setup function.
- **Test scenarios:**
  - Happy path: connecting to a hub serving the modern single-endpoint transport succeeds and uses it for all requests.
  - Happy path: connecting to a hub serving only the legacy two-endpoint transport is detected via the 400/404/405 fallback and used transparently.
  - Edge case: hub unreachable at connect time (connection refused) surfaces a clear error, not a hang.
  - Error path: hub returns an unexpected status code (e.g. 500) on the initial `InitializeRequest` — surfaced as an error, not silently treated as "legacy transport."
- **Verification:** both transport paths connect and complete an initialize handshake against a local test double serving each shape.

### U2. Session lifecycle, reconnection & Neovim-native event API

- **Goal:** manage the MCP session lifecycle and implement reconnection with bounded backoff, exposing hub/client state through Neovim-native autocmds and a client-query API, satisfying R11.
- **Requirements:** R2, R11
- **Dependencies:** U1
- **Files:** `lua/mcp-client/client.lua`, `lua/mcp-client/session.lua`, `lua/mcp-client/reconnect.lua`, `tests/client_spec.lua`, `tests/reconnect_spec.lua`
- **Approach:** track `Mcp-Session-Id`/`MCP-Session-Id` per client instance; echo it and `MCP-Protocol-Version` on every request after initialize. On a 404, transparently reinitialize a new session rather than surfacing an error for that single case. Distinguish an intentional close (this unit's own reconnect teardown, or an explicit disconnect) from a real failure via the `job.user_data.intentional_close` flag KTD: set it before calling `vim.uv.kill(job:pid(), "sigterm")` directly, and check it first in the exit handler attached via `job:add_on_exit_callback`. On any stream-end where that flag is not set, schedule a reconnection attempt using the bounded-backoff KTD; once attempts are exhausted, transition to a visible "disconnected" state and fire the detach event — never leave a caller hanging. Fire `MCPAttach`/`MCPDetach`/`MCPNotify` `User` autocmds with `data = {client_id = ...}`. Expose `get_clients(filter)` and a client object with `id`, `name`, `config`, `is_stopped()`, `request(method, params, handler)`/`notify(method, params)`.
- **Technical design (directional):** the reconnect state machine has three states — `connected`, `reconnecting` (bounded attempts with computed/hinted delay), `disconnected` (attempts exhausted, or an intentional close) — `MCPDetach` fires on the transition into `disconnected`, `MCPAttach` on any transition back to `connected`.
- **Test scenarios:**
  - Happy path: a client that receives a session-scoped 404 reinitializes transparently; the caller's original request retries against the new session without observing an error.
  - Happy path: a dropped connection reconnects successfully within the bounded attempts and fires no visible error.
  - Happy path: an explicit caller-initiated disconnect (the `job.user_data.intentional_close` flag set before `vim.uv.kill`) transitions the client to `disconnected`, fires `MCPDetach`, and schedules no reconnection attempt — confirming the flag actually suppresses the reconnect path rather than merely being set and ignored.
  - Edge case: reconnection attempts are exhausted — the client transitions to `disconnected`, fires `MCPDetach`, and any in-flight request resolves with an error rather than hanging (Covers R11).
  - Edge case: the server sends an SSE `retry:` hint — the computed backoff is overridden by that value for the next attempt.
  - Integration: `get_clients()` reflects the current connection state immediately after each transition, so an adapter polling right after `MCPDetach` sees `is_stopped() == true`.
- **Verification:** a test double that intentionally drops the connection mid-session, and separately returns a session 404, both drive the client through the expected state transitions with no hang (test timeout as the hang-detection mechanism).

### U3. Native in-process server registration

- **Goal:** implement the general mechanism for registering Lua-defined MCP servers that run in-process, exposed through the same client/event API as remote hub connections, satisfying F3.
- **Requirements:** R3
- **Dependencies:** U2
- **Files:** `lua/mcp-client/native.lua`, `tests/native_spec.lua`, `tests/fixtures/example_native_server.lua`
- **Approach:** a native server is a config table (`name`, plus `tools`/`resources`/`prompts` tables of plain Lua functions) registered at core setup, styled after `mcphub.nvim`'s existing `native_servers` shape. Wrap it in the same client interface U2 exposes for remote connections so adapters cannot distinguish a native server from a remote one — request/notify calls short-circuit to direct Lua function calls instead of a network round-trip. No concrete native servers ship in v1 (`orchestrator.lua` is explicitly out of scope, see Key Technical Decisions); this unit proves the mechanism only, via a minimal test-only example server.
- **Test scenarios:**
  - Happy path: a registered native server's tool is callable through the same `request()` path a remote server's tool would use, and appears in `get_clients()`.
  - Edge case: a native server registered with empty capability tables registers without error and is inert.
  - Error path: a native server's tool function raises a Lua error — the error surfaces through the same `(err, result, context)` handler shape a remote error would, not an uncaught exception.
- **Verification:** the test-only example native server's tool is invoked via the public API and returns the expected result with no observable difference from a remote-server call.

### U4. Avante adapter

- **Goal:** expose MCP tools, resources, and prompts to Avante as a thin consumer of the core's public API, replacing `mcphub.extensions.avante`.
- **Requirements:** R4, R6
- **Dependencies:** U2, U3
- **Files:** `lua/mcp-client/adapters/avante.lua`, `tests/adapters/avante_spec.lua`
- **Approach:** translate the core's client/tool listing into Avante's `custom_tools` function and slash-command/prompt registration, following the shape of Avante's existing `custom_tools` integration point but sourced from this plugin's core instead of `mcphub.nvim`'s. The adapter holds no direct hub or transport logic — everything routes through U2's client API (R6).
- **Test scenarios:**
  - Happy path: a tool call issued from an Avante chat buffer resolves through the adapter to a native server (Covers F1).
  - Happy path: a tool call issued from an Avante chat buffer resolves through the adapter to a remote hub connection (Covers F1).
  - Edge case: the core reports zero connected clients — the adapter registers no tools rather than erroring.
  - Integration: a client transitioning to `disconnected` (U2) is reflected in the adapter's tool list on next access, not stale.
- **Verification:** an Avante chat session configured against the adapter can invoke a registered tool and see its result rendered, exercised against both a native server (U3) and a remote test-double hub.

### U5. CodeCompanion adapter

- **Goal:** provide equivalent tool/resource/prompt bridging for CodeCompanion chat, replacing `mcphub.extensions.codecompanion`.
- **Requirements:** R5, R6
- **Dependencies:** U2, U3
- **Files:** `lua/mcp-client/adapters/codecompanion.lua`, `tests/adapters/codecompanion_spec.lua`
- **Approach:** implement as a CodeCompanion extension mirroring the current `extensions.mcphub` callback shape, registering tools and prompts/slash-commands via this plugin's core instead of `mcphub.nvim`. Implement the resource/var bridging path per the MCP spec regardless of CodeCompanion's currently-broken `make_vars` support — if CodeCompanion's `variables` API remains unfixed upstream, document the gap as CodeCompanion's, not work around it silently.
- **Test scenarios:**
  - Happy path: a tool call issued from a CodeCompanion chat buffer resolves through the adapter to a native server and to a remote hub connection (Covers F1).
  - Edge case: resource/var bridging is exercised against CodeCompanion's `variables` API and the outcome (works, or fails with the known gap) is asserted explicitly rather than skipped.
  - Integration: same disconnected-state-reflected-in-adapter scenario as U4, for CodeCompanion's tool list.
- **Verification:** a CodeCompanion chat session configured against the adapter can invoke a registered tool and see its result rendered, exercised against both a native server and a remote test-double hub.

### U6. OAuth discovery & authorization flow

- **Goal:** implement the MCP spec's OAuth 2.1 authorization flow for non-localhost hub connections — Protected Resource Metadata discovery, Authorization Server Metadata discovery, Dynamic Client Registration, and the Authorization Code + PKCE grant via a loopback redirect.
- **Requirements:** R12
- **Dependencies:** U1
- **Files:** `lua/mcp-client/auth/discovery.lua`, `lua/mcp-client/auth/dcr.lua`, `lua/mcp-client/auth/pkce.lua`, `lua/mcp-client/auth/redirect_listener.lua`, `tests/auth/discovery_spec.lua`, `tests/auth/pkce_spec.lua`, `tests/auth/redirect_listener_spec.lua`
- **Approach:** on a 401 from a non-localhost hub, read `WWW-Authenticate` to locate the RFC 9728 protected-resource-metadata URL, fetch it for the `authorization_servers` list, then fetch RFC 8414 metadata for that AS. If the AS advertises a registration endpoint, perform RFC 7591 Dynamic Client Registration to obtain a `client_id`; otherwise fall back to a configured (hardcoded or user-supplied) `client_id` per the spec's documented fallback. Generate a PKCE code verifier/challenge pair and a per-flow `state` parameter, open the system browser (OS-detected `open`/`xdg-open`/`start`) at the authorization endpoint with a `localhost` redirect URI on an OS-assigned ephemeral port and the mandatory `resource` parameter (RFC 8707) bound to the target hub, and run a short-lived local HTTP listener bound explicitly to `127.0.0.1` (never `0.0.0.0`) on that redirect URI to capture the authorization code — rejecting any callback whose `state` doesn't match before accepting the code, and closing immediately after its first callback (success, mismatch, or timeout) rather than remaining open across multiple navigations. When no browser-open mechanism succeeds (e.g. a headless or SSH Neovim session with no reachable GUI), display the authorization URL for the user to open manually elsewhere, with the authorization code entered back manually instead of relying solely on the automatic loopback callback.
- **Technical design (directional):** discovery → (DCR or configured client_id) → PKCE authorization request → loopback redirect capture → token exchange, each stage returning a typed result the next stage consumes; a failure at any stage surfaces a specific, stage-labeled error rather than a generic "auth failed."
- **Test scenarios:**
  - Happy path: a hub whose AS supports DCR completes the full flow (discovery, registration, PKCE authorization, redirect capture) against local test doubles for both the hub and the AS.
  - Happy path: a hub whose AS does not advertise a registration endpoint falls back to a configured `client_id` and completes the remaining flow.
  - Edge case: the redirect listener receives no callback within a timeout (user closes the browser tab) — surfaces a clear timeout error, not a hang.
  - Edge case: a callback with a mismatched or missing `state` parameter is rejected, and the listener closes rather than accepting the code.
  - Edge case: no browser-open command succeeds — the authorization URL and manual-entry fallback are surfaced instead of failing silently.
  - Error path: the AS returns an error during token exchange (e.g. `invalid_grant`) — surfaced distinctly from a network-level failure.
- **Verification:** the full discovery-through-token-exchange flow completes against local test doubles for both the DCR and fallback-client_id paths, with the resulting access token handed off to U7.

### U7. Token management & fail-closed transport security

- **Goal:** manage the OAuth token lifecycle and enforce R12's fail-closed requirement for non-localhost hub connections lacking configured authentication or TLS.
- **Requirements:** R12
- **Dependencies:** U6
- **Files:** `lua/mcp-client/auth/token_store.lua`, `lua/mcp-client/auth/refresh.lua`, `lua/mcp-client/transport/tls.lua`, `tests/auth/token_store_spec.lua`, `tests/auth/fail_closed_spec.lua`
- **Approach:** attach `Authorization: Bearer <token>` to every request the transport sends to a non-localhost hub; rotate the refresh token per the spec's public-client rotation requirement when the access token expires. Before opening a non-localhost connection, `transport/tls.lua` enforces that the hub URL uses `https://` (not implementing TLS itself — `plenary.curl`'s underlying curl process already handles the handshake and certificate verification) and that a configured token/credential is present; if either is missing, refuse the connection outright (fail closed) rather than warning and proceeding, per R12. Tokens persist between Neovim sessions via the OS keychain where a binding is available (e.g. macOS Keychain), falling back to a `0600`-permissioned file under `$XDG_DATA_HOME` when no keychain binding exists — never plaintext in a world-readable location or committed to version control. Auth status surfaced via `:checkhealth mcp-client` (U8) and any error messages report token validity/expiry state without ever printing the token, refresh token, or PKCE verifier value.
- **Test scenarios:**
  - Happy path: every outbound request to a non-localhost hub carries the current bearer token.
  - Happy path: an expired access token triggers a refresh-token exchange transparently before the caller's request is retried.
  - Edge case: a non-localhost hub URL configured with no token and no TLS is refused at connect time with a clear error (Covers R12).
  - Edge case: a localhost hub URL proceeds without requiring auth/TLS, unaffected by this unit's fail-closed check.
  - Edge case: `:checkhealth`/error output for an auth failure never contains the raw token, refresh token, or PKCE verifier text.
  - Error path: a refresh-token exchange fails (revoked token) — surfaces a re-authentication-required error rather than retrying indefinitely.
- **Verification:** the fail-closed check is exercised against a non-localhost URL with no credentials and confirmed refused; a configured non-localhost hub with a valid token connects and every captured request carries the bearer header.

### U8. Configuration, documentation, and health check

- **Goal:** externalize all configuration, document the plugin for third-party adopters, and provide a `:checkhealth`-based status view replacing the rejected dashboard UI.
- **Requirements:** R7, R8
- **Dependencies:** U1, U2, U3, U4, U5, U6, U7
- **Files:** `lua/mcp-client/config.lua`, `lua/mcp-client/health.lua`, `README.md`
- **Approach:** hub URL, server list, native-server registrations, and adapter options are all externally supplied at setup — no personal paths, ports, or credentials in the plugin source (verified by U9's grep check). `lua/mcp-client/health.lua` implements `:checkhealth mcp-client` using `vim.health.start/ok/warn/error`, following the pattern in bundled plugins like `telescope.nvim`'s `health.lua` (no custom health check exists yet in the user's own config) — reporting hub connection status, registered native servers, and auth status. README documents setup, the native-server trust model (full Neovim/Lua privilege, no sandboxing), and hub authentication expectations (R8).
- **Test scenarios:**
  - Happy path: `:checkhealth mcp-client` reports `ok` for a connected hub with valid auth.
  - Edge case: `:checkhealth mcp-client` reports `warn`/`error` (not a crash) when the hub is disconnected or auth has failed.
  - Test expectation: README content is verified by manual review in U9's Definition-of-Done pass, not by an automated spec.
- **Verification:** `:checkhealth mcp-client` runs without error against both a healthy and an unhealthy configured hub, and its output correctly reflects each state.

### U9. Hub-agnosticism & parity validation

- **Goal:** validate the complete plugin end-to-end against both `ravitemer/mcp-hub` and `samanhappy/mcphub`, proving hub-agnosticism, parity, and the resilience/auth requirements together.
- **Requirements:** R9, R10, R11, R12
- **Dependencies:** U1, U2, U3, U4, U5, U6, U7, U8
- **Files:** `tests/integration/hub_agnosticism_spec.lua`, `tests/integration/parity_checklist_spec.lua`, `tests/fixtures/non_localhost_hub_double.lua`
- **Approach:** run the full tool/resource/prompt surface through both adapters against `ravitemer/mcp-hub` first, then unmodified against `samanhappy/mcphub`, asserting identical adapter-facing behavior. Reproduce the reconnect scenario that triggers `ravitemer/mcp-hub`'s SSE re-entrancy bug and confirm the core neither hangs nor crashes (R11). Exercise the R12 fail-closed and successful-auth paths against `tests/fixtures/non_localhost_hub_double.lua` — a local HTTP(S) server bound to a loopback alias other than `localhost` (e.g. `127.0.0.2`) with a self-signed certificate, standing in for a real non-localhost hub (see Risks & Dependencies — the two reference hubs are conventionally localhost-only and don't exercise R12 directly). Check the parity checklist below against `nvim/lua/plugins/ai.lua`'s current `mcphub.nvim` config (dotfiles repo).
- **Test scenarios:**
  - Integration: identical tool-call behavior through both adapters against both hubs (Covers R9).
  - Integration: the SSE re-entrancy reconnect scenario against `ravitemer/mcp-hub` completes without a hang or crash (Covers R11).
  - Integration: the R12 fail-closed and successful-auth paths both exercised against a non-localhost test double.
  - Verification: repo-wide grep finds no hardcoded personal paths, ports, or credentials in `lua/`.
- **Verification:** all scenarios above pass; the parity checklist table is fully checked off.

**Parity checklist** (derived from `nvim/lua/plugins/ai.lua`, dotfiles repo):

| `mcphub.nvim` surface | `mcp-client` equivalent | Status |
|---|---|---|
| `server_url` (hub connection) | R1 core connection, externally configured (R7) | Covered by U1, U8 |
| `native_servers.orchestrator` | Explicitly excluded for v1 (Key Technical Decisions) | Out of scope |
| `extensions.avante` (tools/vars/slash-commands) | U4 Avante adapter | Covered by U4 |
| `extensions.codecompanion` (tools/vars/slash-commands) | U5 CodeCompanion adapter (`make_vars` gap documented, not silently worked around) | Covered by U5 |
| `:MCPHub` interactive dashboard | Explicitly excluded (Key Decisions); replaced by `:checkhealth mcp-client` | Covered by U8 |
| Avante's `disabled_tools` (built-in file/bash ops deferred to MCP) | Host-plugin (Avante) config, not this plugin's responsibility | Out of scope (unaffected) |

### U11. Avante prompt/slash-command bridging

- **Goal:** close the gap R4's own Goal/Approach text already called for but U4 did not build — expose MCP prompts to Avante as slash commands, completing R4's "tools, resources (vars), and prompts (slash commands)" scope.
- **Requirements:** R4, R6
- **Dependencies:** U3 (native `prompts/list`/`prompts/get`, already built and working), U4 (the existing adapter file and its established patterns: `unwrap_result`, the sync/async `request()` hazard, `pcall` defense-in-depth)
- **Files:** `lua/mcp-client/adapters/avante.lua`, `tests/adapters/avante_spec.lua`
- **Approach:** verify Avante's real slash-command/prompt registration mechanism against the locally-installed `avante.nvim` source (the same discipline U4 already applied to `custom_tools` — do not assume the mechanism's shape from memory or from mcphub.nvim's old behavior). U4's implementer never investigated or attempted prompt bridging at all; this is a fresh investigation, not a resumption of partial work. Route prompt discovery/invocation only through the core's public API (`get_clients()`, `request()` for `prompts/list`/`prompts/get`), following R6's "no direct hub/native access" rule and the same cache/refresh pattern U4 already established for tools.
- **Test scenarios:**
  - Happy path: an MCP prompt registered on a native server is invocable as an Avante slash command and its rendered content matches the prompt's `prompts/get` result.
  - Happy path: same, for a prompt exposed by a remote (enveloped) client.
  - Edge case: zero connected clients — no slash commands registered, no error.
  - Integration: a client transitioning to `disconnected` is reflected in the slash-command list on next access, matching U4's existing tool-list staleness handling.
- **Verification:** an Avante chat session can invoke a registered MCP prompt as a slash command and see its rendered content, exercised against both a native server and a remote test-double hub.

### U12. CodeCompanion prompt/slash-command bridging

- **Goal:** close the gap R5's own Goal/Approach text already called for but U5 explicitly scoped out — expose MCP prompts to CodeCompanion via its real prompt-adjacent mechanism, completing R5's "tool/resource/prompt bridging" scope.
- **Requirements:** R5, R6
- **Dependencies:** U3 (native `prompts/list`/`prompts/get`), U5 (the existing adapter file and its established patterns: the `tools_cache`/`resources_cache` model, single-flight refresh, `pcall` defense-in-depth)
- **Files:** `lua/mcp-client/adapters/codecompanion.lua`, `tests/adapters/codecompanion_spec.lua`
- **Approach:** U5's implementer already investigated and documented CodeCompanion's real prompt-adjacent mechanism against the installed source: a class-based `SlashCommand.new/execute/output` registration point, materially larger and structurally distinct from both the `tools` registry and `editor_context` — explicitly scoped out of U5 as "a much larger, separate integration surface" rather than guessed at. This unit is that investigation's follow-through: verify the `SlashCommand` API's exact current shape against the installed `codecompanion.nvim` source (it may have changed since U5), then build the bridging. Route prompt discovery/invocation only through the core's public API, following R6, and reuse U5's existing refresh/cache/pruning pattern rather than inventing a parallel one.
- **Test scenarios:**
  - Happy path: an MCP prompt registered on a native server is invocable as a CodeCompanion slash command and its rendered content matches the prompt's `prompts/get` result.
  - Happy path: same, for a prompt exposed by a remote (enveloped) client.
  - Edge case: zero connected clients — no slash commands registered, no error.
  - Integration: a client transitioning to `disconnected` is reflected in the slash-command list on next access, matching U5's existing tool/resource-list staleness and pruning handling.
- **Verification:** a CodeCompanion chat session can invoke a registered MCP prompt as a slash command and see its rendered content, exercised against both a native server and a remote test-double hub.

### U10. Cutover: switch `ai.lua` to `mcp-client`

**Target repo for this unit: the dotfiles repo (`~/.local/etc`), not `mcp-client`.**

- **Goal:** complete R9/R10's actual finish line by switching the dotfiles repo's Neovim config from `mcphub.nvim` to `mcp-client`.
- **Requirements:** R9, R10
- **Dependencies:** U9 — do not begin until U1-U9's Definition of Done is met.
- **Files (dotfiles repo):** `nvim/lua/plugins/ai.lua`, `scripts/mcphub-launch.sh`, `launchd/agents/com.patrickdeyoreo.mcphub.plist`
- **Approach:** replace the `ravitemer/mcphub.nvim` plugin spec in `ai.lua` with `mcp-client`, configured with the same hub URL and server list currently in use. Decommission the pieces no longer needed once `mcp-client` is confirmed working end-to-end: unload and remove the `com.patrickdeyoreo.mcphub.plist` launchd agent and `scripts/mcphub-launch.sh`'s re-entrancy patch.
- **Test scenarios:**
  - Test expectation: none — this unit is a configuration cutover in a different repo, not new feature code; correctness is verified by using Avante and CodeCompanion chat normally after the switch, per Definition of Done.
- **Verification:** Avante and CodeCompanion chat sessions in the dotfiles Neovim config invoke MCP tools successfully through `mcp-client`, with no reference to `mcphub.nvim` remaining in `ai.lua`.

---

## Verification Contract

| Command | Applies to | Gate |
|---|---|---|
| `make test` (wraps `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"`) | U1-U9 | All specs pass |
| `stylua --check .` | U1-U9 | No formatting diffs |
| `grep -rE "(/Users/|localhost:37373)" lua/` (or equivalent) | U8, U9 | No hardcoded personal paths/ports found |
| Manual: `:checkhealth mcp-client` | U8 | Reports accurate status for healthy and unhealthy hub states |
| Manual: Avante/CodeCompanion chat sessions in the dotfiles repo | U10 | Tool calls succeed through `mcp-client` post-cutover |

## Definition of Done

- All Implementation Units' test scenarios pass via `make test`; `stylua --check .` is clean.
- R1-R12 are each verified true against the parity checklist and integration tests in U9.
- Hub-agnosticism is proven against both `ravitemer/mcp-hub` and `samanhappy/mcphub`, including the reconnect/crash-injection scenario (R11) and both the fail-closed and successful-auth paths (R12).
- README and `:checkhealth mcp-client` are complete and accurate; no hardcoded personal paths, ports, or credentials remain in `lua/`.
- Dead-end or experimental code from approaches that didn't pan out during implementation is removed, not left in the diff.
- `ai.lua` (dotfiles repo) is switched over to `mcp-client` and the `mcphub.nvim`-specific launchd agent/launch script are decommissioned (U10) — the concrete finish line for R9/R10.
