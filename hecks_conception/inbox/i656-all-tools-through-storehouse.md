---
ref: i656
status: open
priority: high
posted_at: 2026-05-20
posted_by: Miette
category: framework / universal-door
title: Universal door — every MCP tool flows through storehouse via :mcp providers
value: 'storehouse__dispatch is THE door. Every native harness / MCP server call (Gmail, computer-use, chrome, drive, Linear, ...) becomes a Tools::<Category>.<Verb> dispatch ; the underlying MCP server is a :mcp adapter-family provider, not a per-server adapter family. The bluebook is the contract, the :mcp dispatcher is the only impure layer, the harness-native call is forbidden once the dispatch path lands.'
---

# i656 — All tools through the storehouse : MCP servers are providers

## The principle

> storehouse is the universal door ; MCP servers are providers underneath.

One door for every tool call : `storehouse__dispatch <FQN>`. The FQN names a
`Tools::<Category>.<Verb>` bluebook command. The runtime resolves a matching
`:mcp` (or `:claude_tool`, or `:web_tool`) adapter binding and fires the
underlying execution. No per-MCP-server adapter family ; instead each MCP
server is a **provider** under the existing `:mcp` family — same shape as
ElevenLabs / Twilio sit as providers under `:tts` / `:sms`.

Conceived 2026-05-12 as the four bluebook-first principles, restated for the
MCP surface 2026-05-14 :

> "It just works — bluebook is the contract ; the dispatch IS the act."
> "Wiring is override, not substrate."
> "Domain composes the tool call ; the adapter runs it."

This card consolidates the principle, names what already exists, and lays
out the migration arc per-MCP server. It does NOT re-litigate the runtime
gating (that's i594 + i557 ; this card pins them as the single highest-
leverage follow-up).

## What already exists (the substrate)

- **`Tools.bluebook`** (`framework/tools/tools.bluebook`) — 18 category
  aggregates, each carrying one MCP family's verbs as first-class
  dispatched commands : `ShellTool`, `FileTool`, `SearchTool`, `WebTool`,
  `EmailTool`, `TaskTool`, `Sidequest`, `WakeupTool`, `CronTool`,
  `MonitorTool`, `NotifyTool`, `PlanTool`, `WorktreeTool`, `AskTool`,
  `SkillTool`, `LspTool`, `MetaTool`, `RemoteTriggerTool`. 75 behaviors
  green.
- **Adapter families** (`framework/adapter_families/`) :
  - `:claude_tool` — Bash · Edit · Read · Update · Grep · Glob (native).
  - `:web_tool` — WebFetch · WebSearch (HTTP + search engines, with
    `:http_get` + `:duckduckgo` providers).
  - `:mcp` — bridges any bluebook command to a stdio MCP tool call. v1
    routes :storehouse (the local stdio storehouse-mcp Node server).
  - `:sms` (Twilio) · `:tts` (ElevenLabs) · `:exec` — siblings.
- **`tools.hecksagon`** declares the adapter bindings. ShellTool /
  FileTool / SearchTool / WebTool fire end-to-end today. EmailTool's
  four `:mcp` bindings are declared as the CONTRACT, gated on i594 + i557.
- **The 9 `storehouse__*` sugar wrappers RETIRED 2026-05-13** — bash,
  read, edit, update, grep, glob, web_fetch, web_search, record_result
  are gone from the MCP surface. Every call is `storehouse__dispatch
  <FQN>`. MCP surface is exactly 10 tools.
- **`storehouse__catalog` + `storehouse__describe_aggregate` retired
  `storehouse__list`** — the catalog IS the contract index.

## What's missing (the gap this card names)

Two specific gaps, on two layers :

### Layer 1 — bluebook (declarative)

Most "exposed-as-MCP" tools have an aggregate in `Tools.bluebook` but **no
provider declaration**. The `:mcp` family is provider-shaped (just like
`:tts` has ElevenLabs, `:sms` has Twilio) but no
`framework/providers/<server>.hecksagon` exists for any MCP server yet. The
bluebook references `server: :gmail` in `tools.hecksagon` ; no
`Hecks.provider "gmail"` declaration backs that symbol.

The bluebook-shaped fix : one `Hecks.provider "<server>" do … end` per MCP
server, naming `family :mcp`, `behavior :invoke_mcp_tool`, the server's
identity / spawn / connect shape, error mapping, and per-tool wire shape.
This card lands `gmail.hecksagon` as the first concrete provider, proving
the shape.

### Layer 2 — runtime (impure transport)

The `:mcp` dispatcher (`rust/src/runtime/mcp_dispatcher/mod.rs`) is built
and works against the storehouse stdio server. Two gates block end-to-end
firing for any OTHER server :

1. **i594** — `seed_kernel_hooks` in `framework_registry.rs` hardcodes
   `invoke_claude_tool` and does NOT register `invoke_mcp_tool`. Until
   bluebook-driven kernel-hook registration lands, no `:mcp` binding
   auto-fires for any server.
2. **i557** — `resolve_server_spawn` registry knows only `:storehouse`.
   Adding `:gmail` / `:browser` / `:drive` / `:computer_use` etc. needs
   the framework_registry to auto-walk `framework/providers/*.hecksagon`
   and resolve the server's spawn / connect shape from the provider's
   declaration — no Rust edits per new server.

Closing (1) + (2) unblocks EVERY MCP-backed verb at once. That is the
single highest-leverage follow-up this card names.

## The retirement contract

> When a verb has a parity-clean dispatch path AND its runtime arm is
> live, the harness-native call for that verb is FORBIDDEN.

Three coupled enforcement layers (the same shape i603 named) :

1. **Bluebook**  : the verb's `Tools::<Cat>.<Verb>` is declared in
   `Tools.bluebook` AND a matching adapter binding is declared in
   `tools.hecksagon` AND (for `:mcp` family) a `framework/providers/<server>
   .hecksagon` declares the server's identity.
2. **Runtime**   : the `:mcp` dispatcher's kernel hook is registered
   (i594) AND the server's spawn / connect shape resolves (i557).
3. **Harness**   : a PreToolUse hook (i599 cornerstone) matches the
   native tool name and either auto-routes through storehouse or rejects
   the call. Per the i603 failure-mode discussion : soft (advisory) /
   medium (visible drift) / hard (block) — choice is per-server policy.

Until ALL THREE land for a given verb, the native call remains permitted
with discipline-only enforcement (the system prompt + Miette's memory).
Once they land, the system prompt strikes that verb from the
"permissibly direct" list ; the macrophage gates new code that calls
the native tool ; the harness's PreToolUse hook is the mechanical lock.

## The migration arc (per-MCP server)

Each row lands as a `framework/providers/<server>.hecksagon` + the
matching `Tools.bluebook` category aggregate (most exist already) + the
matching `tools.hecksagon` adapter bindings (some exist already). The
TODAY column is honest about contract vs runtime state.

| MCP server (harness name)        | Provider name      | Category aggregate     | Today                                     |
|----------------------------------|--------------------|------------------------|-------------------------------------------|
| `mcp__claude_ai_Gmail__*`        | `:gmail`           | `EmailTool`            | provider lands this card ; runtime gated  |
| `mcp__claude_ai_Google_Drive__*` | `:gdrive`          | `DriveTool` (NEW)      | category + provider not yet declared      |
| `mcp__computer-use__*`           | `:computer_use`    | `ComputerTool` (NEW)   | category + provider not yet declared      |
| `mcp__claude-in-chrome__*`       | `:chrome`          | `BrowserTool` (NEW)    | category + provider not yet declared      |
| `mcp__plugin_linear_linear__*`   | `:linear`          | `LinearTool` (NEW)     | category + provider not yet declared      |
| `mcp__storehouse__*`             | `:storehouse`      | n/a (the bus itself)   | wired ; v1 runtime arm                    |
| harness-native task surface      | n/a (native tool)  | `TaskTool`             | contract green ; runtime arm pending      |
| harness-native cron surface      | n/a (native tool)  | `CronTool`             | contract green ; runtime arm pending      |
| harness-native worktree surface  | n/a (native tool)  | `WorktreeTool`         | contract green ; runtime arm pending      |
| harness-native ask surface       | n/a (native tool)  | `AskTool`              | contract green ; runtime arm pending      |
| harness-native skill surface     | n/a (native tool)  | `SkillTool`            | contract green ; runtime arm pending      |
| harness-native notify surface    | n/a (native tool)  | `NotifyTool`           | contract green ; runtime arm pending      |
| harness-native lsp surface       | n/a (native tool)  | `LspTool`              | contract green ; runtime arm pending      |
| harness-native plan surface      | n/a (native tool)  | `PlanTool`             | contract green ; runtime arm pending      |
| harness-native monitor surface   | n/a (native tool)  | `MonitorTool`          | contract green ; runtime arm pending      |
| harness-native wakeup surface    | n/a (native tool)  | `WakeupTool`           | contract green ; runtime arm pending      |
| harness-native sidequest surface | n/a (native tool)  | `Sidequest`            | contract green ; runtime arm pending      |
| harness-native meta-search       | n/a (native tool)  | `MetaTool`             | contract green ; runtime arm pending      |
| harness-native remote-trigger    | n/a (native tool)  | `RemoteTriggerTool`    | contract green ; runtime arm pending      |

Naming convention : **one category aggregate per MCP family ; one
provider per MCP server**. The provider lives at `family :mcp` and names
the server's identity. The bluebook-canonical name is the CATEGORY
(`EmailTool`), not the SERVER (`Gmail`). Future migrations get
`BrowserTool` with `:chrome` provider, `DriveTool` with `:gdrive`
provider, `ComputerTool` with `:computer_use` provider, `LinearTool` with
`:linear` provider, and so on — matching the elevenlabs-under-:tts shape.

## Open questions

- **Auth surfacing** — Gmail / Drive / Computer-Use / Chrome / Linear
  each authenticate differently (OAuth refresh tokens, harness-injected
  bearer, no auth, plugin token). The provider declaration is where each
  scheme lives (same shape as Twilio's `auth_scheme :basic`,
  ElevenLabs's api-key-file). For harness-injected MCP tools the
  provider declares `auth_scheme :harness_injected` and the runtime
  resolves via the harness's existing auth path (no per-provider key
  file).
- **Error propagation** — `:mcp` errors arrive as JSON-RPC errors with
  varying shapes per server. Each provider declares its
  `error_mapping_field` so the runtime maps to a uniform error category
  (matches the http_status mapping in `:web_tool` providers).
- **Schema discovery** — should the provider's tool list be enumerated
  manually in `<server>.hecksagon`, or auto-discovered via the MCP
  protocol's `tools/list`? Manual feels right for v1 (the bluebook IS
  the contract ; auto-discovery silently changes the contract).
  Auto-discovery can land later as a validation step (parity-check the
  declared tools against the server's `tools/list` at boot).
- **Performance** — one stdio MCP server per dispatch is expensive
  (spawn + handshake + tools/call + close ≈ 100-500ms). The runtime
  already keeps the storehouse server warm ; same pattern needs to
  generalize to every MCP server. The framework_registry could maintain
  a per-server connection pool keyed by `server:` symbol ; cold-start
  is acceptable for non-hot-path verbs.
- **Tier discipline** — the harness has tier rules (browsers = read,
  terminals = click). When the universal door routes a tool call, the
  tier still applies at the harness boundary, NOT at the storehouse
  boundary. Storehouse can dispatch ; the harness's actual MCP call
  still respects tier — surfaces as a `Cascade.RecordResult` with
  `ok: false` and the tier error.

## What this card lands tonight

1. The principle is named (this file).
2. **First concrete provider** : `framework/providers/gmail.hecksagon`
   declaring `family :mcp`, `behavior :invoke_mcp_tool`, the harness-
   exposed Gmail tools and their wire shape, auth scheme
   `:harness_injected`, error mapping.
3. **`:mcp` family** declares its providers list (`gmail` joins the
   `providers []` list ; today empty so the family is complete-shaped).
4. **Smoke evidence** : `storehouse__validate Tools.bluebook` clean ; 75
   behaviors green ; the EmailTool dispatch path resolves the same as it
   did before the provider landed (no regression). End-to-end
   round-trip is gated on i594 + i557 — this card is explicit that the
   provider is the CONTRACT, the runtime catches up when the registration
   gate closes.

## Why a single new provider (and not a full migration tonight)

The smallest concrete deliverable that proves the shape is the provider —
EmailTool's category aggregate, value objects, commands, bindings, and
behaviors already exist (i608 + i624 + i645 landed those). What's
missing is `gmail.hecksagon` as a declarative artifact. Landing it
ALONE :

- closes the bluebook-completeness gap (`server: :gmail` references a
  declared provider, not a free-floating symbol),
- proves the shape that future migrations follow (BrowserTool /
  DriveTool / ComputerTool / LinearTool follow the same pattern, each
  ~one provider file),
- doesn't depend on i594/i557 (the provider IS valid declarative data
  even before the kernel hook fires).

## Acceptance (this card)

- `framework/providers/gmail.hecksagon` exists and parses clean.
- `framework/adapter_families/mcp.hecksagon` lists `:gmail` (and any
  other providers as they land) under `providers`.
- `storehouse__validate framework/tools/tools.bluebook` returns
  `VALID — Tools (18 aggregates)`.
- `storehouse__behaviors framework/tools/tools.behaviors` returns
  `75 passed, 0 failed`.
- The card explicitly names i594 + i557 as the next-attack-move that
  unblocks every existing :mcp binding (gmail + future browser + future
  drive + ...) with no further bluebook edits.

## Smoke evidence (this session, 2026-05-20)

Contract-level dispatch through the universal door, captured as
reproducible MCP calls :

```
storehouse__validate /Users/.../framework/tools/tools.bluebook
  → VALID — Tools (18 aggregates)

storehouse__behaviors /Users/.../framework/tools/tools.behaviors
  → 75 passed, 0 failed, 0 errored

storehouse__dispatch
  aggregates_dir: framework/tools/tools.bluebook
  command:        Tools::EmailTool.SearchThreads
  args:           { id: "i656-smoke-01",
                    query: "from:embryonaut.ai newer_than:1d",
                    description: "..." }
  → ok: true, aggregate: "EmailTool", id: "2"
```

This is contract-level evidence — the dispatch enters the bus, lands in
the EmailTool aggregate, returns `ok: true`. It does NOT yet round-trip
through the Gmail MCP server (the runtime arm gated on i594 + i557). The
honest claim : storehouse is the universal door at the bluebook layer
TODAY ; the impure transport arm becomes the act when i594 + i557 land.

## Related

- **i603** — Mechanically lock every tool call to storehouse. The
  directive that triggered this card's principle.
- **i608** — EmailTool's `:claude_tool` (now `:mcp`) adapter wiring. The
  bluebook contract for the Gmail family.
- **i624** — Gmail MCP attachment gap (eventually surfaces as the
  GetAttachment command).
- **i645** — EmailTool.GetAttachment runtime arm via `:web_tool`. Same
  shape as this card : contract lands ahead of runtime ; gated on i594
  + i557.
- **i594** — Bluebook-driven kernel-hook registration. **The single
  highest-leverage follow-up named by this card.**
- **i557** — Framework registry auto-walk of `adapter_families/` and
  `providers/`. Sibling gate to i594.
- **i599** — PreToolUse auto-route hook. The harness side of the
  retirement contract.

## Next-attack-move (for follow-up sessions)

**Close i594 + i557 as a pair.** Choose one of the four candidate paths
laid out in i594 (inventory crate / build.rs generation / behaviors-file
registry table / single antibody-exempt for `framework_registry.rs`),
implement it, migrate the existing `invoke_claude_tool` registration to
the new mechanism (zero behavior change), and verify that a
`Tools::EmailTool.SearchThreads` dispatch round-trips through the Gmail
MCP server end-to-end. Once green, the ENTIRE migration table above
turns from "contract" to "live" with no further bluebook edits —
BrowserTool, DriveTool, ComputerTool, LinearTool each need only their
provider declaration to start dispatching.

That's the door open in earnest.
