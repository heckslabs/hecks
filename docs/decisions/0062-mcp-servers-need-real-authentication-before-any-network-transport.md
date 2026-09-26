# The MCP servers stay stdio-only, and a network transport needs real authentication first

**Status:** Proposed (draft). The stdio gate described under "What is enforced today" shipped with this ADR. Nothing under "Decision" is built, and this ADR does not authorize building a network transport; it says what has to be true before anyone does.

## Context

`bin/hecks_mcp_door` (the Storehouse bus, `lib/hecks/storehouse.rb`) and `bin/hecks_query_ir_mcp` (structural queries over the language, `lib/hecks/query_ir.rb`) are registered in `.mcp.json` and speak MCP over stdio. An outside production-readiness review (item 8) said both are unauthenticated beyond a caller-asserted `role`/`actor_id`. That is true of the door and slightly understated for the query-IR server, which has no identity at all. The README already said both are stdio-only and self-asserted; before this change nothing in the code enforced either statement.

### What is enforced today

| Claim | Enforced by | Proved by |
| --- | --- | --- |
| Both servers run only over stdio | `Hecks::McpStdioGuard.enforce_stdio!`, called before either server loads anything: refuses an argument other than `--stdio`, any `HECKS_MCP_*` variable except `HECKS_MCP_TRANSPORT=stdio`, and an IP socket as stdin or stdout (the shape a `socat`/`inetd` wrapper produces). A Unix-domain socket is accepted, because some MCP clients spawn servers over a `socketpair`. | `spec/mcp_servers_spec.rb` |
| Startup says what is and is not protected | `McpStdioGuard.warn!`, written to stderr only (stdout carries the protocol) | `spec/mcp_servers_spec.rb` |
| A role-gated command is refused when the caller supplies no role | `Storehouse.require_caller_for_role_gated!`, for `dispatch`, `dry_run` and every step of a batch, in the short and qualified spellings | `spec/storehouse_spec.rb`, and through the real door in `spec/mcp_servers_spec.rb` |
| `domain:` cannot boot code outside the project root | `Storehouse.confine!` against `BOOT_ROOT` | `spec/storehouse_spec.rb` (`domains`, `validate`) |
| `query_ir_duplicates` cannot load Ruby from outside the project root | `confined_domains` in `bin/hecks_query_ir_mcp`, using the same `confine!` | `spec/mcp_servers_spec.rb` |

### What is not enforced, and is not authentication

- **Identity is a string the caller sends.** `role: "Chef"` is accepted as Chef. With `actor_id:` and Governance attached, the bus checks a real `Governance::RoleAssignment`, but the caller still chooses which `actor_id` to claim. Nothing binds either to a person or a credential.
- **`query` cannot be role-gated.** Role is a command-only word in the DSL. Query authorization is a separate mechanism (`Runtime::TenantScope`, an explicit `tenant:` argument), so a query runs the same for no caller, a forged caller and a real one. This is the documented behavior, now specified in `spec/storehouse_spec.rb`; this ADR does not change it.
- **The readers take no identity.** `state`, `events`, `history`, `follow`, `describe` and `catalog` return stored records, payloads and the audit log to any caller.
- **`domain:` and `behaviors` execute Ruby.** `Hecks.boot` runs `Kernel.load` on the domain's files. Confinement to `BOOT_ROOT` limits which files, not whether code runs. `HECKS_STOREHOUSE_ROOT` widens the root, and a symlink under the root is followed.
- **The audit log records claims.** `role`, `actor_id` and `source` in the log are what the caller said.
- **The gate cannot see a proxy.** A process that reads a network socket and writes into an ordinary pipe leaves the server's stdin a pipe. The gate closes the configurations that announce themselves.

The only thing standing between a stranger and either server is that reaching stdin means already being able to run the process.

## Decision (proposed)

1. **Stay stdio-only.** Both servers keep refusing any other transport. Remote use goes through a transport that authenticates the person and hands the server a pipe, for example `ssh host bin/hecks_mcp_door`. The gate accepts that, and the person is authenticated by SSH rather than by the request body.
2. **`bin/hecks_query_ir_mcp` never gets a network transport.** It is meta-tooling for working on hecks and loads bluebooks as Ruby.
3. **If the Storehouse bus is ever served over a network, it is a new door beside the stdio one, not a flag on it,** and it does not ship until all of the following hold.
   - **Transport.** MCP over HTTP with TLS, bound to loopback unless an operator opts in, with `Origin` checking so a browser page cannot drive a local server.
   - **Authentication.** Every request carries a credential the server verifies before parsing the tool call: OAuth 2.1 bearer tokens as the MCP authorization specification describes, or mutual TLS. A shared static secret is acceptable only for a single-operator deployment, and it gives no per-principal audit.
   - **Identity comes from the credential.** The principal is derived from the verified token. `role:` and `actor_id:` request arguments are rejected when a principal is present, and roles are looked up from `Governance::RoleAssignment` for that principal. The audit log records the principal, and records claimed fields separately.
   - **Every tool is authorized, not only `dispatch`.** The readers get per-tool grants. `query` is bound to the principal's tenant through `Runtime::TenantScope`.
   - **No code loading per request.** A network door serves an allowlist of domains booted at startup. `domain:` paths, `validate`, `behaviors` and `domains` do not accept caller-supplied paths there.
   - **Limits.** Request size, per-principal rate limits and per-call time limits, because a caller can now be anyone with a token.
4. **The claim stays checkable.** Any network door adds specs that send an unauthenticated request, a forged token and a valid token with a forged `role:`, and prove the first two are refused and the last is ignored.

## Alternatives considered

- **Put the existing door behind a reverse proxy that authenticates.** Rejected as the whole answer: the proxy authenticates a connection, but the door would still take `role:` from the request body, so any authenticated user could claim any role.
- **A shared secret in an environment variable.** Simplest, and enough for one operator. No per-person identity, no revocation short of rotation, and the audit log still cannot say who acted.
- **Only document the limits (the status quo).** Kept as the fallback, but a README sentence does not stop a `socat` wrapper, which is why the stdio gate exists.

## Consequences

- Remote agents use SSH or another authenticated pipe until a network door exists. That is a stated limit, not a bug.
- `HECKS_MCP_*` is a reserved namespace: any variable in it, other than `HECKS_MCP_TRANSPORT=stdio`, stops the servers from starting. A future network door needs a different entry point or an explicit amendment to this ADR.
- `query_ir_duplicates` no longer scans `domains:` outside the project root; relative paths now resolve against `BOOT_ROOT` instead of the server's working directory. Inside a checkout that launches the server from its root, they resolve the same.

## Open questions

- Is a network door wanted at all, or is SSH enough for every foreseeable deployment?
- Where do principals live: Governance in each domain, or one identity provider in front of all of them?
- Should the readers require a role at all on stdio, or is "whoever can run the process may read" the intended boundary there?
- Should `HECKS_STOREHOUSE_ROOT` and symlink following be refused rather than documented?
