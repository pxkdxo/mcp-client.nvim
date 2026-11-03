# mcp-client.nvim

A from-scratch [Model Context Protocol (MCP)][mcp] client for Neovim, with an
LSP-inspired core and thin adapters for [Avante][avante] and
[CodeCompanion][codecompanion]. It connects to standards-compliant MCP servers over
Streamable HTTP (with a legacy HTTP+SSE fallback), hosts native in-process
servers, and exposes their tools/resources/prompts to your AI plugins — all
through the standard MCP endpoint, with no server-proprietary management API.
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

| Field       | Type     | Description                                                                 |
| ----------- | -------- | --------------------------------------------------------------------------- |
| `url`       | string   | **Required.** The server's MCP endpoint URL.                                   |
| `name`      | string   | Optional. Defaults to the map key (or `"default"` for the `server` shorthand). |
| `headers`   | table    | Optional. Extra headers merged into every request.                          |
| `reconnect` | table    | Optional. Backoff tuning: `initial_delay`, `max_delay`, `growth_factor`, `max_attempts`. |
| `auth`      | table    | Optional. `{ token_store = <TokenStore> }` to supply your own store (see below). |

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

-- MCP-derived slash commands: call this once after setup(), and again from an
-- MCPAttach/MCPDetach autocmd to keep the list current as clients
-- connect/disconnect. (A table handed through setup()'s `slash_commands` opt
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
-- Call require("codecompanion").extensions["mcp-client"].refresh() from an
-- MCPAttach/MCPDetach autocmd to keep the tool list current as servers connect and
-- disconnect.
```

Both adapters read tool/resource listings from the live client registry, so a
server that connects or disconnects after startup is reflected on the next tool
resolution.

---

## Health check

Run `:checkhealth mcp-client` to see, per configured server:

- **connection status** — connected / disconnected / never-connected;
- **auth status** — authenticated / token expired / no token — reported from
  redacted status fields only (the token itself is **never** printed);
- **registered native servers**, with the trust-model reminder alongside.

A disconnected server or a missing/expired token is reported as a `warning` or
`error` — the check never crashes on an unhealthy configuration.

---

## Events

The client fires `User` autocmds you can hook:

| Pattern      | When                                              | `data`                    |
| ------------ | ------------------------------------------------- | ------------------------- |
| `MCPAttach`  | a client connects (initial connect or reconnect). | `{ client_id = <string> }` |
| `MCPDetach`  | a client disconnects (reconnect exhausted).       | `{ client_id = <string> }` |
| `MCPNotify`  | the server sends a notification.                  | `{ client_id = <string> }` |

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "MCPAttach", "MCPDetach" },
  callback = function()
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

Each client object exposes `id`, `name`, `config`, `is_stopped()`,
`request(rpc, cb)`, `notify(rpc)`, and `disconnect()`.

[mcp]: https://modelcontextprotocol.io/
[avante]: https://github.com/yetone/avante.nvim
[codecompanion]: https://github.com/olimorris/codecompanion.nvim
[lazy]: https://github.com/folke/lazy.nvim
[curl]: https://curl.se/
[plenary]: https://github.com/nvim-lua/plenary.nvim
[mcphub]: https://github.com/samanhappy/mcphub
