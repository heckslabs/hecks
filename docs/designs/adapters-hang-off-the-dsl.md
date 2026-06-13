# Locked design : adapters hang off the DSL (ports & adapters, two-color)

> Review/handoff artifact. SUPERSEDES the invented `subscription do … end`
> syntax in `inbox/restarts_inbox/adapter-trigger-result-grammar-2026-06-12.md`.
> "Documentation is the bluebook — no separate prose docs." If greenlit this
> becomes the card contract / an Epic in Plan, then this markdown is deleted.
>
> Locked with Chris, 2026-06-12 (evening dialogue).

## The shape

Hexagonal. The `.hecksagon` IS the hexagon — the ports-and-adapters ring around
a synchronous domain core.

## The hierarchy (hexagonal, corrected)

| Thing | Example | What it is |
|---|---|---|
| **Aggregate** | `Pizza::Orders` | the domain / hexagon core — sync. The thing a port hangs off ; NOT itself a port |
| **Port** | `persisted_by`, `charged_by` | the **explicitly declared** boundary — carries its verb, its signal (reply/effect), its round-trip edges. Lives in a family |
| **Family** | persistence, payment | a **group of ports**. The organizing unit |
| **Adapter** | `'Heki'`, `'Shell'` | the concrete **async** implementation. Declares which family it implements |

## The declaration chain

    hex  declares  the adapter
    adapter  declares  its family
    family  is a group of  ports
    ports  are  explicitly declared

The hex's only new act is **picking the adapter**. The port and family pre-exist
as framework declarations ; the adapter carries its family with it. So one line
of composition decomposes as `aggregate . port ( adapter )` :

    Pizza::Orders . persisted_by ( 'Heki' )
       aggregate      port            adapter

- `persisted_by` is the **port** — explicitly declared, lives in the persistence
  family.
- `'Heki'` is the **adapter** — the hex declares it ; Heki's own definition
  declares `family: persistence`.
- The bind **resolves iff Heki's declared family contains the `persisted_by`
  port**. That is the attach checkpoint — now TYPED through the family, not
  matched against a loose string. Nonsense (an adapter whose family lacks the
  port) fails the attach, loudly, at wiring.

## Six locked properties

### 1. Two-color rule — domain sync, adapters async
- **Domain = sync. Always.** No tokio, no Mutex, no channel, no IO ever appears
  in aggregate logic. The domain composes effects (events) and receives
  commands — full stop.
- **Adapter = async. Always.** Every async concern — latency, retries, backoff,
  timeouts, database IO — lives EXCLUSIVELY at the bus boundary.
- The color is **free**. Adapters never declare async/sync; there is nothing to
  set, because "adapter" *means* async. `delivery :sync` / `delivery :actor`
  RETIRES — that fork only existed because the color was once modelled as a
  per-aggregate flag. Under the two-color rule the seam is structural, not
  configured.

### 2. Adapters hang off the real DSL
The aggregate FQN is already the language's reference for an aggregate; it
carries `.Command` (PascalCase) and `.snake_case` (query). The bound port is the
**third verb category** on that same reference:

    Pizza::Orders.PlaceOrder              # command — changes it
    Pizza::Orders.board                   # query   — reads it
    Pizza::Orders.persisted_by('Heki')    # port+adapter — wires its async edge

No separate `adapter :shell do … end` surface to handwrite → the imperative
muscle memory has nowhere to fire (restart-card addendum pt 3).

### 3. One round-trip, one verb path
A reply port is one verb. An effect port (event-out → async → command-in) is
ALSO one verb — the whole round-trip on a single path, NOT split across the
event and command references:

    Pizza::Orders.charged_by('Shell', on: 'OrderPlaced', into: 'Authorize | Decline')

`on:` = the event the aggregate emits (inbound edge); `into:` = the command(s)
the async outcome re-enters as (outbound edge, a discriminated union —
success→Authorize, failure→Decline). Both edges are carried by the ONE port
verb.

The round-trip binding IS the **Subscription** — keep that name (Directive 1).
Its only fields are the edges (`on`/`into`, i.e. trigger/result). It needs NO
`description` ; the edges ARE the whole contract. Expressed as the port's own
signature — not two loose struct fields, and not a prose-described object.

### 4. Families are groups of explicitly-declared ports
The port vocabulary is **open**, organized into families. Each port is
explicitly declared — its verb, its signal, its edges. A family groups related
ports (persistence groups `persisted_by` …; payment groups `charged_by` …). An
ADAPTER declares which family it implements ; the family is NOT named in the hex
(the adapter carries it).

### 5. The port carries the signal
Reply-port vs effect-port is NOT inferred from argument shape — it is intrinsic
to the port, declared where the port is declared:
- a **reply-port** returns a value to the synchronous domain (the domain sees a
  plain `find` that returns; the port bridges with a oneshot bounded by
  `timeout_ms`). `persisted_by` is reply-port.
- an **effect-port** round-trips: fire-and-forget event out, verdict re-enters
  as a command. `charged_by` is effect-port.

The port knows which it is; the author never states it.

### 6. Three files, three concerns
| File | Concern | Holds |
|---|---|---|
| `.bluebook` | **the domain** | the sync hexagon core — pure, portable, knows no adapter |
| `.hecksagon` | **composition** | which adapter fills which port on which aggregate — verbs, ports, adapter NAMES only; NO values |
| `.world` | **configuration** | every tunable value — endpoint_env, token_env, timeout_ms, retries, backoff, the heki `dir` |

Values live ONLY in the bottom file. Configuration can't leak up into
composition; composition can't leak into the domain. Swap the world → same
composition, same domain, different deployment. This is what makes the domain
portable.

## What this supersedes
The restart card's change-surface (lift `trigger_on`/`result_into` into a shared
Subscription STRUCT, parse them on the `:shell` arm) was the right mechanism at
the IR level but the wrong SURFACE. The surface is not a struct with two
fields — it is a **port bound off the aggregate FQN, filled by an adapter that
declares its family**. Directive 1 (the Subscription) and Directive 2 (project
to Rust) fuse: the port IS the declaration, and the typed round-trip it carries
is exactly what projects to typed async Rust (the generated worker knows the
event payload and the command attributes → typed glue, not stringly dispatch).

## Open / verify with a fresh head
- Exact port signatures per family (positional vs keyword `on:` / `into:`).
- How the adapter→family→port resolution is spelled : where the adapter declares
  its family, where ports are declared in the family, and how the hex bind
  type-checks against the loaded bluebook at parse/attach.
- Projection: each bound port → its async Rust worker; the whole domain → sync
  functions. The bus boundary is the only seam where the two colors meet.
- Migration: the flat `adapter :shell, name:, trigger_on:, result_into:` form is
  replaced wholesale (no first user; no compat shim).
