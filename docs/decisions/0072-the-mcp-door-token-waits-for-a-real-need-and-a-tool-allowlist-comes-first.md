# The MCP door's caller token waits for a network door or multi-agent wiring, and a tool allowlist comes first

**Status:** Accepted — not yet implemented. Date: 2026-09-27. Both triggers below have since been answered by the maintainer (2026-09-27): multi-agent use is near, so decision 2, the allowlist, is being built as its own change; and a network door is wanted, so decision 1's token design is now a prerequisite and is being mapped in `docs/wayfinder/mcp-network-door/`. Nothing in decision 1 is built. This ADR builds on [ADR 0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) and changes none of it: the servers stay stdio-only, and the token design stays as 0062 lays it out.

## Context

ADR 0062 says a network door needs real authentication. Over stdio, identity is still a string the caller sends: `role`, `actor_id` and `source` come straight from the tool arguments (`bin/hecks_mcp_door:331-340`), and the audit log records those claims. `Hecks.as_caller` binds them for the call (`lib/hecks/storehouse.rb:251-254`), and `CommandRules::Authorization#refuse_role_mismatch` compares them to the command's role, or to a Governance role assignment when an `actor_id` is given (`lib/hecks/runtime/command_rules/authorization.rb:47-65`). The read tools take no role, and `domain:` runs `Kernel.load` under `BOOT_ROOT`, which `HECKS_STOREHOUSE_ROOT` widens (`lib/hecks/storehouse.rb:117`).

The question was whether stdio should get a local shared secret or a signed caller token now. The real stdio threat is another process of the same user, which can read an inherited environment variable or a key file just as the door can. A local secret would stop proxies, other OS users and sandboxed processes, and nothing else. It would not identify anyone, so it would add the look of authentication without the substance.

Two other facts bear on the timing. `docs/decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md` adds a `hecks mcp` subcommand, which exposes the door from an installed gem; 0066 leaves auth as a release blocker for that release if the door is a product surface. And the Rust host has the same gap on its serve and invoke path: `role` is read from the request body (`rust/host/src/server.rs:102`), while only the web path derives it from an HMAC-signed session cookie (`rust/host/src/auth.rs:10-19`).

## Decision

1. **No shared secret and no signed token now.** The token is designed once, as ADR 0062 lays it out: the verified principal replaces the caller-supplied `role:` and `actor_id:`, roles are looked up through Governance, and forged-token specs are required (0062:34-41). That happens when a network door or multi-agent wiring is real.
2. **A per-tool capability allowlist is added if multi-agent use is near.** A spawned door is limited to reader tools, with no `dispatch`, no `domain:` and no `behaviors`. This shrinks the code-execution and write surface per agent without cryptography. It identifies no one and is not authentication.
3. **This is independent of network transport for stdio, and a prerequisite only for a network door** (0062:34-41).
4. **The Rust host's body-asserted `role` (`rust/host/src/server.rs:102`) is the same self-asserted gap.** Parity between the Ruby door and the Rust serve and invoke path is decided together when the token is built.

## Consequences

- Stdio identity stays self-asserted, as 0062 and the door's startup warning already state. Nothing in this ADR weakens the stdio guard (`lib/hecks/mcp_stdio_guard.rb:133-137`).
- Until the allowlist or the token exists, a `hecks mcp` install exposes the whole tool set, including `domain:` code loading, to anyone who can spawn it.
- The allowlist gives a spawned agent less reach than the current door, and gives the audit log nothing new.

## Alternatives considered

- **An environment shared secret.** Cheap, and it stops proxies and other OS users. It does not help against a same-user process, gives no per-principal audit, and the guard refuses every `HECKS_MCP_*` name except `HECKS_MCP_TRANSPORT=stdio` (`lib/hecks/mcp_stdio_guard.rb:41-42`), so using that prefix would need an amendment to ADR 0062. 0062:36 already accepts a static secret only for a single operator.
- **A signed caller token now.** It composes with Governance and would give real audit identity, but needs minting, expiry, revocation and key handling, and would be designed a second time when a network door arrives. Rejected for now, not for good.
- **Defer everything with no allowlist.** No code change, and the residual risk stays documented. Kept as the choice while multi-agent use is not near.

## Open items

- ~~When is multi-agent use near?~~ Answered 2026-09-27: near enough to build the allowlist now.
- Which tools count as readers for the allowlist, and is `query` among them? Settled by the build, which classifies each tool by reading its code; the change lists the classification.
- ~~Is a network door wanted at all, or is SSH enough?~~ Answered 2026-09-27: a network door is wanted. Decision 1's token design is therefore a prerequisite; its open questions are ticketed in `docs/wayfinder/mcp-network-door/`.
- Do principals live in each domain's Governance or in one identity provider?
- Should stdio readers require a role, or is "whoever can spawn the door may read" the boundary?
- Should `HECKS_STOREHOUSE_ROOT` and symlink following be refused rather than documented?
