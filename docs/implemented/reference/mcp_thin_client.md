# The MCP server is a client of the control process

`hecks-mcp` (`.mcp.json`) starts `Mcp.serve_stdio`. After the stdio guard it asks the checkout's
resident, over the existing unix socket, to serve the session on this process's own stdin, stdout
and stderr (`Mcp::Thin`, through `Resident::Client.ask` with the line `mcp! --stdio`). The caller
loads no domain and no MCP server of its own. The socket keeps its trust checks (0600, same-user
peer) and its cold path.

- **Control down or busy:** the entry says `hecks: control process down, running cold` on stderr
  and serves the session itself, as before.
- **The guard runs twice:** in the caller, and again in the resident's child on the streams it
  received, so a tty or non-stdio transport is refused either way.
- **The resident retires or goes away mid-session:** the child ends, the client says so on stderr
  and ends with status 1, and the editor starts the server again, which finds a fresh resident or
  serves cold. A session is a long-held child under the resident; the wait has no time limit while
  the resident's process stands (`Waiting`).
- **Hooks:** `.claude/hooks/message_inbox.sh` boots nothing per step; a hook that calls
  `exe/hecks` already tries the socket first (a warm `RedFlag.status` takes about 0.46 s through
  the launcher), so no separate hook client was added.
- **Behaviors:** no bluebook changed, so no `.behaviors` were added.
