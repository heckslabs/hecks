---
type: grilling
status: closed
blocked_by: []
claimed_by:
---

# MCP door auth: a caller token before any multi-agent wiring

## Question

ADR 0062 says MCP servers need real authentication before any network transport. Even over
stdio, `role` and `actor_id` are self-asserted. Decide whether stdio gets a local shared secret
or a signed caller token now, how it composes with the Governance grant check, and whether this
is a prerequisite for network transport or independent of ADR 0062.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision.

**Facts**
- Enforced at startup: `McpStdioGuard.enforce_stdio!` refuses any argument but `--stdio`, any
  `HECKS_MCP_*` variable except `TRANSPORT=stdio`, and IP-socket stdin or stdout
  (`lib/hecks/mcp_stdio_guard.rb:40-42,126-158`). `domain:` is confined to a boot root
  (`storehouse.rb:117-137`), and role-gated `dispatch` and `dry_run` refuse without a `role:`
  (`storehouse.rb:276`).
- Caller-asserted: `role`, `actor_id` and `source` (`bin/hecks_mcp_door:20-29,109-121`), and the
  audit log records those claims. Read tools (`state`, `events`, `history`, `follow`,
  `describe`, `catalog`) take no role, and `bin/hecks_query_ir_mcp` has no identity at all.
- Any stdin writer can run Ruby: `domain:` calls `Kernel.load` under the boot root, and
  `HECKS_STOREHOUSE_ROOT` widens that root (ADR 0062:24).
- Identity reaches the grant check through `Hecks.as_caller(role:, actor_id:)`
  (`storehouse.rb:251-254`), read by `CommandRules::Authorization#refuse_role_mismatch`
  (`runtime/command_rules/authorization.rb:47-65`). A verified token would be checked in the
  door before that call and would replace the request's `role:` and `actor_id:`; the runtime
  needs no change.
- Rust parity is partial: the web path derives the role from an HMAC-signed session cookie
  (`rust/host/src/auth.rs:10-19`), while the serve/invoke path takes `role` from the request
  body (`rust/host/src/server.rs:102`).
- Threat model: over stdio the spawner is any local process of the same user. An inherited
  environment secret or a key file adds nothing against that user; it stops proxies, other OS
  users and sandboxed processes. Neither fixes forgery unless a token is minted per principal
  with the role inside it. `domain:` runs Ruby whatever the credential.
- ADR 0062 accepts a static shared secret only for a single operator with no per-principal
  audit (`:36`, `:46`), says a token's principal replaces `role:` and `actor_id:` (`:37`) and
  requires forged-token specs (`:41`). Its open questions are at `:55-60`.

**Options**
1. Environment shared secret. Cheap; stops proxies and other users. The guard currently refuses
   every `HECKS_MCP_*` name, so it needs an ADR amendment or another variable name. No identity.
2. Signed caller token with a key file, principal and role inside, HMAC like `auth.rs`.
   Composes with Governance and gives real audit identity; needs minting, expiry, revocation
   and key handling.
3. Defer to the network-transport ADR. No code change; residual risk stays documented.
4. Per-tool capability allowlist (for example a spawned door restricted to reader tools, no
   `dispatch`, `domain:` or `behaviors`). Shrinks the code-execution and write surface per
   agent with no crypto; identifies no one.

**Recommendation from prep.** Option 3 now, with option 4 as the one cheap addition. A local
secret protects nothing against a same-user process, which is the real stdio threat, and would
add a false sense of authentication. Do the token design once, as ADR 0062 lays out. If
multi-agent wiring is imminent, ship the allowlist first. This ticket is independent of
network transport for stdio and a prerequisite only for a network door.

**For the maintainer**
1. Is multi-agent wiring on a date? If not, deferring is safe.
2. Is a network door wanted at all, or is SSH enough?
3. Do principals live in each domain's Governance or in one identity provider?
4. Should stdio readers require a role, or is "whoever can spawn it may read" the boundary?
5. Should `HECKS_STOREHOUSE_ROOT` and symlink following be refused?
6. Should the Rust host's body-asserted `role` be decided together, for parity?

## Answer

Decided 2026-09-27: no shared secret and no signed token now. The token is designed once, as
ADR 0062 lays it out, when a network door or multi-agent wiring is real. A per-tool capability
allowlist (readers only, no `dispatch`, `domain:` or `behaviors`) is added if multi-agent use is
near. Independent of network transport for stdio, a prerequisite only for a network door.
Recorded in
[ADR 0072](../../../decisions/0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md).
