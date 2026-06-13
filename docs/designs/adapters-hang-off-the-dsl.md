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

The round-trip needs NO name — not "Subscription", not "Binding". **The verb
carries the semantics.** `charged_by` already says "fires on an event, returns a
command" (effect-port) ; `persisted_by` says "backs storage, returns a value"
(reply-port). The verb's declaration in its family IS the whole contract — no
wrapper object, no `description`. The edges (`on`/`into`) are the verb's own
signature where it has them ; a reply-port verb carries none.

(The pre-existing `Subscription` value object in `hecksagon_ir.bluebook` is a
DIFFERENT concept — the cross-domain `subscribe "OtherDomain"` edge — and is
untouched. This design introduces NO "Subscription" ; it is extra to the UL.)

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
two-field STRUCT, parse them on the `:shell` arm) was the right mechanism at
the IR level but the wrong SURFACE. The surface is not a struct with two
fields — it is a **port bound off the aggregate FQN, filled by an adapter that
declares its family**. Directive 1 (the trigger/result edges) and Directive 2 (project
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

## Worked example — written in the hecksagon (impure adapter vs cross-domain)

The wiring lives in the `.hecksagon` either way — a bluebook-as-adapter does NOT
wire itself ; the cross-domain edge is still declared in the hexagon. The
aggregate IS the port definition (`Pizza::Order`'s events/commands ARE the
contract) ; `persisted_by` / `charged_by` are NOT port methods — they are how we
implement, specifically, via an adapter. Cross-domain needs no how-verb and no
adapter : the target aggregate's command fills the port directly.

```ruby
# pizzas.hecksagon — Pizza::Order is a PORT DEFINITION ; two implementations.
Hecks.hecksagon "Pizzas" do

  # IMPURE — the payment gateway crosses the purity boundary, so it needs an
  # ADAPTER. `charged_by` is how we implement, specifically : payment, via the
  # Shell adapter. The async verdict re-enters the SAME domain.
  Pizza::Order.charged_by("Shell",
                          on:   "OrderPlaced",
                          into: "Order.Authorize | Order.Decline")

  # REPLY — persistence is also impure (disk IO), so also an adapter. No edges :
  # a reply port returns a value, the domain sees a plain find/save that returns.
  Pizza::Order.persisted_by("Heki")

  # CROSS-DOMAIN — Order's authorized event ROUTES into the Fulfillment domain
  # through a FULFILLMENT ADAPTER : a domain-routing adapter (async, like every
  # adapter) whose job is to carry the call from one domain to another. It does
  # no external IO — the Fulfillment bluebook's aggregate DIRECTLY implements
  # the contract (no implementation code written). The bluebook works as the
  # adapter ; the routing IS the adapter.
  Pizza::Order.on("OrderAuthorized").into("Fulfillment::Shipment.Release")

end
```

TWO adapter kinds, both async, both wired in the hexagon :
- an **impure adapter** (`charged_by("Shell")`, `persisted_by("Heki")`) does
  external IO and crosses the PURITY boundary ;
- a **domain-routing adapter** (the fulfillment adapter above) routes a call from
  one domain to another and crosses the DOMAIN boundary, delegating to a target
  aggregate that DIRECTLY implements the contract — the bluebook works as the
  adapter, no implementation code written.

The only adapter-free, synchronous path is INTRA-domain (aggregate->aggregate,
same domain, by naming convention). Everything that LEAVES a domain — impure
outside OR another domain — is an async adapter. That is exactly why "we only
wire cross-domain in the hexagon" : leaving the domain is what needs an adapter.

### How a port is fulfilled at runtime — the adapter calls storehouse

The aggregate-port calls the adapter to fulfil it ; the adapter fulfils the port
by calling the STOREHOUSE (the bus) to dispatch a command. The storehouse is the
universal door — `storehouse.dispatch("Domain::Aggregate.Command", …)`. So `into`
names the command the adapter dispatches :

- **Fulfillment (domain-routing) adapter** — calls `storehouse.dispatch(
  "Fulfillment::Shipment.Release", …)`. The bus lands it in the OTHER domain,
  which handles it synchronously within itself. The storehouse call IS the
  routing ; the Fulfillment bluebook is what works as the adapter.
- **Impure effect adapter** (gateway) — runs its external IO, THEN calls
  `storehouse.dispatch` to put the verdict (`Order.Authorize | Order.Decline`)
  back into the SAME domain. `result_into` is literally the command it dispatches.

Same mechanism either way : the adapter is async, and its act of fulfilment is a
storehouse dispatch. `on` is the event that calls the adapter ; `into` is the
command the adapter dispatches through storehouse to fulfil the port.

This is the SAME thing today's parseable `driven on EVENT do dispatch
"Other::Agg.Command" end` form already does (the cross-domain dispatch target is
a pure aggregate command, no adapter struct) — the FQN-verb surface above is its
target spelling, hung off the aggregate-port instead of a `driven` block.

## CONCEIVED — the hexagon bluebook is now the source of truth

The model is conceived as a validated bluebook :
`aggregates/language/grammar/hexagon.bluebook` (+ `.behaviors`, 7 green).
Where this prose and the bluebook differ (some earlier sections still show an
`into` FQN on the binding), the **bluebook wins**. Final shape :

- **Hexagon** (root) — `domain`, `has_many Binding` ; commands `Conceive` and
  `Verify` (optional startup wiring check).
- **Family** — `name`, `verb` (the how-verb, e.g. `persisted_by`), `signal`
  (reply | effect), `has_many Field`.
- **Field** — one config field NAME (the value lives in `.world`).
- **Adapter** — `name`, `belongs_to Family`. **No FQN** : the adapter
  declaration already knows which domain it routes to.
- **Binding** — `aggregate` (own-domain port), `on` (triggering event),
  `has_one Adapter`. References ONLY its own domain.

Locked structural rules : single-direction relationships (**never
bidirectional**) ; **no `list_of`** (collections are `has_many`) ; an adapter is
anything **outside the domain boundary** (persistence, HTTP, calling another
bluebook). A bluebook never references another bluebook directly — the adapter is
the indirection. Cross-domain wiring is the **hexagon's job at RUNTIME** through
storehouse (**runtime discovery**) ; `Hexagon.Verify` is the optional fail-fast
that moves a misconfiguration from first-fire to startup — the
flexibility/safety trade-off made explicit.
