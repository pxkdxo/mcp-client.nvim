# mcp-client.nvim

A from-scratch [Model Context Protocol (MCP)][mcp] client for Neovim, with an
LSP-inspired core and thin adapters for [Avante][avante] and
[CodeCompanion][codecompanion]. It connects to standards-compliant MCP servers over stdio or
Streamable HTTP (with a legacy HTTP+SSE fallback), hosts native in-process
servers, and exposes their tools/resources/prompts to your AI plugins — all
through the standard MCP protocol, with no server-proprietary management API.
It speaks MCP 2026-07-28 and falls back to the handshake-based revisions
(2025-11-25 back to 2024-11-05) for servers that have not moved yet.
Any spec-compliant server works; [mcphub][mcphub] is a maintained example of a
multi-server hub if you want one.

- **Module name:** `require("mcp-client")` (deliberately *not* `require("mcphub")`).
- **Requirements:** Neovim 0.10+, [plenary.nvim][plenary], and [`curl`][curl] on
  `PATH` (the transports and the OAuth flow shell out to `curl` through
  `plenary.curl` rather than hand-rolling TLS).

> **Security note up front:** native servers run **in-process, with full
> Neovim/Lua privilege — there is no sandboxing.** Only register native servers
> you trust as first-party code. See [Native servers and the trust model](#native-servers-and-the-trust-model).

---

## Installation

With [lazy.nvim][lazy]:

```lua
{
  "pxkdxo/mcp-client.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    -- see Configuration below
  },
}
```

lazy.nvim calls `require("mcp-client").setup(opts)` for you. With any other
plugin manager, install `nvim-lua/plenary.nvim` alongside this plugin and call
`setup()` yourself from anywhere in your config:

```lua
require("mcp-client").setup({
  -- see Configuration below
})
```

`setup()` is idempotent: calling it again re-reads your configuration and
re-registers everything. It never triggers an interactive login (see
[Authenticating a server](#authenticating-a-server)).

---

## Configuration

All configuration is supplied by you at `setup()` — the plugin ships **no**
hardcoded URLs, ports, paths, or credentials. Every value below is a
placeholder; substitute your own.

```lua
require("mcp-client").setup({
  -- A single server (shorthand). Its name defaults to "default".
  server = { url = "http://localhost:PORT" },

  -- Or one or more named servers (a name -> server-config map).
  -- Use `servers` instead of `server` when you connect to more than one.
  servers = {
    local_server  = { url = "http://localhost:PORT" },
    remote_server = { url = "https://your-server.example.com/mcp" },
    -- A stdio server: launched as a subprocess, restarted if it exits.
    stdio_server  = { command = "npx", args = { "-y", "your-mcp-server" }, env = { API_KEY = "..." } },
  },

  -- How this client answers servers that ask it for input (see "Client
  -- features" below). Applies to every server; a server's own `handlers`
  -- override these key by key.
  handlers = {
    roots = function(ctx) return { { uri = vim.uri_from_fname(vim.fn.getcwd()) } } end,
  },

  -- Native, in-process servers (a name -> server-config map). Each server is a
  -- plain table of Lua functions; see "Native servers" below. The map key is
  -- used as the server name unless the config sets its own `name`.
  native_servers = {
    my_server = require("my.native.server"),
  },

  -- Defaults for auto-constructed OAuth token stores (non-localhost servers only).
  token_store = {
    backend   = nil, -- "keychain" | "file" | nil (auto-detect: keychain on
                     -- macOS if `security` is available, else a 0600 file)
    data_home = nil, -- override $XDG_DATA_HOME for the file backend (rarely needed)
    key       = nil, -- optional shared prefix, namespaced per-server as "<key>:<server name>"
                     -- (e.g. for a per-machine/per-profile prefix); never a verbatim
                     -- override, so it can never collapse two servers onto one stored token
  },
})
```

### Server config fields

Each server config is passed through to the client's `connect()`; the fields it
understands:

| Field              | Type     | Description |
| ------------------ | -------- | ----------- |
| `url`              | string   | The server's MCP endpoint URL (HTTP). Exactly one of `url` or `command` is required. |
| `command`          | string   | The executable to launch for a stdio server. |
| `args`             | string[] | Optional. Arguments for `command`. |
| `env`              | table    | Optional. Environment variables added to the stdio server's inherited environment. |
| `cwd`              | string   | Optional. Working directory for the stdio server. |
| `name`             | string   | Optional. Defaults to the map key (or `"default"` for the `server` shorthand). |
| `headers`          | table    | Optional. Extra headers merged into every HTTP request. |
| `handlers`         | table    | Optional. Per-server client-feature handlers; see [Client features](#client-features-roots-elicitation-sampling). |
| `timeout`          | number   | Optional. Milliseconds allowed for each connection step (default 10000). |
| `discover_timeout` | number   | Optional. stdio only: milliseconds to wait for a reply to the modern discovery probe before treating the server as legacy (default 3000). |
| `reconnect`        | table    | Optional. Backoff tuning: `initial_delay`, `max_delay`, `growth_factor`, `max_attempts`. |
| `auth`             | table    | Optional. `{ token_store = <TokenStore> }` to supply your own store (see below). |

### Protocol support

Each connection works out which protocol era the server speaks:

- **Modern (2026-07-28).** Stateless: every request carries its protocol
  version and the client's capabilities in `_meta`. Over HTTP the client also
  sends `Mcp-Method`, `Mcp-Name`, and the `Mcp-Param-*` headers a tool's
  `x-mcp-header` annotations ask for (a tool with invalid annotations is left
  out of `tools/list`). List-change notifications arrive on a
  `subscriptions/listen` stream, and requests that need your input
  (`input_required`) are answered and retried automatically.
- **Legacy (2025-11-25 and earlier).** The `initialize` /
  `notifications/initialized` handshake, Streamable HTTP sessions and the GET
  notification stream, and the 2024-11-05 HTTP+SSE transport.

Over HTTP the client first sends a modern `server/discover` and falls back to
the legacy handshake when the server does not answer it as a modern server
would. Over stdio it sends the same probe and treats a server that rejects it,
or does not reply within `discover_timeout`, as legacy. `:MCPStatus` shows what
each connection negotiated.

---

## Client features (roots, elicitation, sampling)

Servers can ask the client for information while handling a request — legacy
servers by sending a request, modern servers by returning `input_required`.
The client answers through `handlers`, set in `setup()` for every server or in
a server's own config:

| Handler       | Signature                      | Default |
| ------------- | ------------------------------ | ------- |
| `roots`       | `fun(ctx): Root[]`             | The current working directory. |
| `elicitation` | `fun(params, ctx, respond)`    | Prompts with `vim.ui.select` / `vim.ui.input`. |
| `sampling`    | `fun(params, ctx, respond)`    | None — sampling is not offered unless you provide one. |

`ctx` is `{ server = <server name> }`. `respond(err, result)` completes the
request with an `ElicitResult` or `CreateMessageResult` (or an error). Set a
handler to `false` to turn the feature off; the client then stops declaring
the matching capability.

The default elicitation handler names the server asking, collects each form
field (enums and booleans as a picker, numbers and strings validated against
the schema), and shows a review step before anything is sent. For a URL
request it shows the full URL and its host and opens it with `vim.ui.open`
only after you choose to. Escaping any prompt cancels.

```lua
require("mcp-client").setup({
  handlers = {
    sampling = function(params, ctx, respond)
      -- Call your model of choice with params.messages, then:
      respond(nil, { role = "assistant", content = { type = "text", text = "..." }, model = "my-model" })
    end,
  },
})
```

---

## Native servers and the trust model

A native server is an **in-process** MCP server: a plain Lua table with
`tools` / `resources` / `prompts` sub-tables of Lua functions. It answers
`tools/call`, `resources/read`, and `prompts/get` by calling those functions
directly — no subprocess, no network.

```lua
-- my/native/server.lua
return {
  name = "my_server",
  tools = {
    add = function(args) return { total = args.a + args.b } end,
  },
  tool_meta = {
    add = {
      description = "Add two numbers",
      inputSchema = {
        type = "object",
        properties = { a = { type = "number" }, b = { type = "number" } },
        required = { "a", "b" },
      },
    },
  },
  resources = {},
  prompts = {},
}
```

> **Trust model (read this):** a native server's functions run **in your Neovim
> process, with full Neovim/Lua privilege** — the same access your own config
> has. **There is no sandboxing, no capability restriction, and no
> confirmation prompt** around what a native server's code can do (filesystem,
> shell, network, editor state). Treat a native server exactly as you would any
> other Lua module you `require` into your config: **only register native
> servers whose source you trust as first-party code.** An LLM can *invoke* a
> native tool, but the tool's *code* is yours — the LLM never supplies it.

Native servers and remote servers are indistinguishable to the adapters: both
appear in `get_clients()` wearing the same client-object shape, so your AI
plugin sees their tools uniformly.

---

## Server authentication

`mcp-client` enforces a **fail-closed transport-security policy**:

- A **localhost** server (`localhost`, `127.0.0.1`, `::1`, `0.0.0.0`) may be plain
  `http://` with no credential.
- A **non-localhost** server must use **`https://` AND have a bearer token
  configured.** A non-localhost server that is missing TLS or a token is
  **refused outright** — the client will not send an unauthenticated request
  over an insecure or unauthenticated non-localhost connection.

For a non-localhost server, `setup()` automatically constructs a persistent
`TokenStore` (keyed by the server name) and threads it into the connection, so a
stored token is reused across Neovim sessions and refreshed transparently when
it expires. Tokens are stored in the OS keychain where available (macOS
`security`), otherwise in a `0600`-permissioned JSON file under
`$XDG_DATA_HOME/mcp-client/` — never world-readable, never inside the plugin
or your repo.

You can supply your own store instead:

```lua
local TokenStore = require("mcp-client.auth.token_store")
require("mcp-client").setup({
  servers = {
    remote_server = {
      url  = "https://your-server.example.com/mcp",
      auth = { token_store = TokenStore.new({ key = "remote_server" }) },
    },
  },
})
```

### Authenticating a server

The plugin **does not** auto-open a browser login flow on startup — that would
prompt on every launch and is an undesigned UX surface for v1. When a
non-localhost server has no stored token yet, the connection fails closed with
a clear message, and you authenticate **explicitly**, using the OAuth 2.1
Dynamic-Client-Registration flow (RFC 7591 + PKCE), via `:MCPAuth`:

```vim
:MCPAuth
:MCPAuth remote_server
```

Run `:MCPAuth` with no argument and it resolves the target for you: if exactly
one configured server currently needs authentication, it authenticates that
one; if none do, it tells you there's nothing to do; if more than one does, it
lists the candidates and asks you to re-invoke with an explicit name instead of
guessing. Naming a server directly (`:MCPAuth remote_server`, tab-completable)
always runs the flow for that server, even if it already has a valid,
unexpired token — useful for rotating credentials early.

On success, the new token is saved under the same store key `setup()` itself
resolves, and only that server is reconnected — other configured servers are
left untouched. `:MCPAuth` discovers the server's authorization server,
registers a client, opens your browser to authorize, and completes on a
loopback redirect.

For scripting outside an Ex command (after `setup()` has already run), call the
same action `:MCPAuth` itself dispatches to:

```lua
require("mcp-client.commands").authenticate("remote_server")
```

This reuses the server's existing store (never a reconstructed key) and its
retained connection settings, exactly like `:MCPAuth remote_server` would.

Before ever calling `setup()`, there is no registered server state yet to
reuse, so the underlying OAuth flow is directly callable instead:

```lua
local dcr   = require("mcp-client.auth.dcr")
local store = require("mcp-client.auth.token_store")

dcr.run_flow({ server_url = "https://your-server.example.com/mcp" }, function(token, err)
  if err then
    vim.notify("MCP auth failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  -- Key must match the server name you use in setup() so the stored token is found.
  store.new({ key = "remote_server" }):save(token)
  vim.notify("MCP server authenticated; re-run setup() or restart Neovim.")
end)
```

---

## Wiring the adapters

`setup()` connects servers and registers native servers; the adapters are wired
into your AI plugins separately (each plugin owns its own integration point).

### Avante

```lua
require("avante").setup({
  custom_tools = require("mcp-client.adapters.avante").custom_tools,
  -- Your own manually-configured slash commands go here, if any -- MCP-derived
  -- ones are wired separately below, not through this opt.
})

-- MCP-derived slash commands: call this once after setup(), and again from the
-- autocmd under "Events" below to keep the list current. (A table handed through setup()'s `slash_commands` opt
-- does NOT stay in sync automatically -- avante.nvim deep-copies opts during
-- setup(), so this adapter instead writes directly into the live
-- `require("avante.config").slash_commands` array on every refresh.)
require("mcp-client.adapters.avante").refresh()
```

### CodeCompanion

```lua
require("codecompanion").setup({
  extensions = {
    ["mcp-client"] = {
      callback = require("mcp-client.adapters.codecompanion"),
    },
  },
})
-- Call require("codecompanion").extensions["mcp-client"].refresh() from the
-- autocmd under "Events" below to keep the tool list current.
```

Both adapters read tool/resource listings from the live client registry, so a
server that connects or disconnects after startup is reflected on the next tool
resolution.

---

## Commands

| Command                  | Action |
| ------------------------ | ------ |
| `:MCPStatus`             | Show each server's connection state, transport, protocol era and version, server identity, stdio pid and last stderr line, and auth status. |
| `:MCPReconnect [server]` | Reconnect one configured server, or all of them. |
| `:MCPAuth [server]`      | Run the OAuth flow for a server (see [Authenticating a server](#authenticating-a-server)). |
| `:MCPLogout <server>`    | Delete a server's stored token and disconnect it. |

---

## Health check

Run `:checkhealth mcp-client` to check that plenary.nvim and `curl` are
available and to see, per configured server:

- **connection status** — connected (with transport and negotiated protocol)
  / disconnected / never-connected;
- **auth status** — authenticated / token expired / no token — reported from
  redacted status fields only (the token itself is **never** printed);
- **registered native servers**, with the trust-model reminder alongside.

A disconnected server or a missing/expired token is reported as a `warning` or
`error` — the check never crashes on an unhealthy configuration.

---

## Events

The client fires `User` autocmds you can hook:

| Pattern      | When                                              | `data` |
| ------------ | ------------------------------------------------- | ------ |
| `MCPAttach`  | a client connects (initial connect or reconnect). | `{ client_id, server }` |
| `MCPDetach`  | a client disconnects (reconnect exhausted).       | `{ client_id, server }` |
| `MCPNotify`  | the server sends a notification.                  | `{ client_id, server, method, params }` |

Refresh an adapter whenever a server connects, disconnects, or reports that
its tools, prompts, or resources changed:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "MCPAttach", "MCPDetach", "MCPNotify" },
  callback = function(ev)
    local changed = (ev.data.method or ""):match("list_changed$")
    if ev.match == "MCPNotify" and not changed then
      return
    end
    pcall(function()
      require("codecompanion").extensions["mcp-client"].refresh()
    end)
  end,
})
```

---

## Programmatic API

| Call                                                         | Purpose                                          |
| ------------------------------------------------------------ | ------------------------------------------------ |
| `require("mcp-client").setup(opts)`                       | The entrypoint (validates config, connects servers, registers native servers). |
| `require("mcp-client.client").get_clients(filter?)`       | Live client objects (`filter` = `{ id?, name? }`). |
| `require("mcp-client.native").register(config)`           | Register one native server directly.             |
| `require("mcp-client.auth.token_store").new(opts)`        | Construct a `TokenStore`.                         |
| `require("mcp-client.auth.dcr").run_flow(opts, cb)`       | Run the interactive OAuth flow (manual auth).    |
| `require("mcp-client.rpc").list_all(client, method, field, cb)` | Fetch every page of a `*/list` method, e.g. `("tools/list", "tools")`. |
| `require("mcp-client.rpc").next_id()`                     | A JSON-RPC request id that never collides with the plugin's own. |

Each client object exposes `id`, `name`, `config`, `transport`
(`"stdio"`, `"streamable_http"`, `"legacy_sse"`, or `"native"`), and for
remote servers `era` (`"modern"` or `"legacy"`), `protocol_version`,
`server_info`, `server_capabilities`, `instructions`, and `pid` (stdio).
Methods: `is_stopped()`, `state()`, `request(rpc, cb)`, `notify(rpc)`,
`stderr()` (stdio), and `disconnect()`. `request` handles the protocol era for
you — request metadata, header mirroring, and `input_required` retries — so
callers send plain JSON-RPC.

[mcp]: https://modelcontextprotocol.io/
[avante]: https://github.com/yetone/avante.nvim
[codecompanion]: https://github.com/olimorris/codecompanion.nvim
[lazy]: https://github.com/folke/lazy.nvim
[curl]: https://curl.se/
[plenary]: https://github.com/nvim-lua/plenary.nvim
[mcphub]: https://github.com/samanhappy/mcphub
