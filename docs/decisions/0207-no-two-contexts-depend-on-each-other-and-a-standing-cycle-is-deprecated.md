# No two contexts depend on each other, and a standing cycle is deprecated

**Status:** Accepted. Date: 2026-11-14. Asked for by the owner ("I want to make this impossible in
Hecks"), after the board's wiring showed Agents and Hecks each reacting to the other's events.
Narrows [0135](0135-a-context-map-is-declared-and-the-wiring-is-checked-against-it.md), whose cycle
finding was a warning over two kinds of edge, and adds a kind to the relationship acknowledgements of
[0150](0150-a-finding-is-acknowledged-on-the-declaration-it-excuses.md).

## Context

`ModelCheck.context_cycle_findings` already grouped contexts that reach each other. It let the
Hecks domain's own cycles through for three reasons:

- **It warned.** A warning fails nothing, so a cycle could be added and landed.
- **It read two kinds of edge.** Only an `across` policy and a `translates` counted. An `attaches`
  was read as a shared kernel "with no direction" and a `subscribe` as a listener, and both were left
  out. But a context that attaches another loads its model and reacts to its events, and one that
  subscribes cannot be understood without the event's owner: each is a dependency, with a direction.
- **The map wrote the cycle down.** `hecks.contextmap` declared `"Hecks" => "Agents"` as an
  anti-corruption layer and `"Agents" => "Hecks"` as a shared kernel, with a comment that the second
  had no direction. The same two lines stood for QualityControl, Coder and Delivery.

The cost is the one a cycle always has. Hecks' delegate bluebook starts a session on the Agents
bluebook's request events, and the Agents bluebook judges a verdict on Hecks' `AgentRun` events, so
a change to a role edits the bluebook that starts every session, and neither can be read alone.

## Decision

1. **Every edge between two contexts is a dependency.** A cycle is read over `attaches`,
   `subscribe`, `across` and `translates` alike (`ModelCheck::ContextCycles::DEPENDENCY_KINDS`).
   A context's edge to itself is not one.
2. **A cycle is an error.** `model_check` fails on a group of contexts that reach each other, and
   says the two ways out: move the reactions to one side's hecksagon so one context is upstream, or
   make them one context.
3. **A cycle that stood before the rule is accepted on its relationship, and is deprecated.** A
   `.contextmap` relationship takes `accepted_findings: { context_cycle: "reason" }`. An accepted
   pair is reported as a warning that says it is deprecated and names the release that refuses it
   (`ContextCycles::REFUSED_FROM`, 8.0.0). This is the only way a cycle passes.
4. **An accepted pair is read as one context while it stands.** A longer ring that runs through an
   accepted pair is still an error, so an acceptance cannot be used to let a new context into the
   cycle.
5. **An acceptance the wiring no longer needs is reported.** Once a pair is untangled its
   acceptance is a `context_cycle_settled` warning that says to remove it, so the list shrinks.
6. **`model_check` reads a source's context map.** Its own boot (`ModelCheck::Sources`) loaded a
   source's bluebooks and hecksagons and never its `.contextmap`, so the declared map of ADR 0135
   was held to the wiring by specs and by the `Introspection.context_map` query, and not by
   `model_check` as that record says. The boot now loads the map last, which is also what lets a
   run see the cycles a map accepts.
7. **The Hecks domain's own list can only shrink.** `hecks.contextmap` accepts the pairs that
   stood (Hecks with Agents, Coder, Delivery and QualityControl), and
   `spec/context_map_hecks_cycles_spec.rb` holds its accepted pairs to that list: a pair may be
   removed from the spec and never added.

## Alternatives considered

- **Untangle every standing pair first, then make the cycle an error.** Cleaner, with no
  acceptance at all. Rejected: nothing would be protected until the last pair was done, and a new
  cycle could land meanwhile.
- **A baseline file of known cycles beside the check.** The custom cops keep one. Rejected here:
  the context map is already where a relationship is declared and where a finding about it is
  accepted with a reason (ADR 0150), so a second file would say the same thing in another place.
- **Allow a cycle between contexts declared as a `partnership`.** Evans names it as a mutual
  relationship. Rejected: it would make one word the way round the rule. A partnership is still
  declared, and its pair still needs an acceptance to cycle.
- **Refuse both directions when the map file loads.** The builder could reject a pair related both
  ways. Not built: a map may declare a relationship the wiring does not have, and the cycle is in
  the wiring, which only `model_check` reads.

## Consequences

- A new cycle between contexts fails `model_check` wherever it runs, in Hecks and in a client
  project, including one made only of an attach on one side and a subscription on the other.
- A client project whose contexts already depend on each other sees an error after it upgrades.
  It accepts the pair in its context map with a reason and gets the deprecation in place of the
  error, until 8.0.0.
- The Hecks domain reports its standing pairs as deprecated on every `model_check`. Untangling
  each is its own work; the largest is Agents and Hecks, where the policies in the delegate
  bluebook that listen for the Agents bluebook's events would become `translates` in a hecksagon.
- With the map loaded, a `model_check` of the whole corpus on 2026-11-14 reported the standing
  pairs as deprecated and nothing else about a context: no declared relationship of the Hecks or
  Banking maps disagreed with its wiring.
- The refusal at 8.0.0 and the untangling of the Hecks domain's four pairs are in the addendum below.

## Addendum: from 8.0.0 an accepted cycle is refused (2026-11-27)

**The refusal.** From 8.0.0 a relationship's `accepted_findings: { context_cycle: "…" }` excuses no
cycle. Decisions 3 and 4 no longer hold: an accepted pair is not read as one context, and its cycle
is an error like any other. The error names the acceptance ("which excuses no cycle from 8.0.0")
beside the two ways out. An acceptance whose wiring no longer cycles is still the
`context_cycle_settled` warning that says to remove it. No release reads the running version:
the code that refuses ships in 8.0.0.

**Where it is refused.** In `model_check`, not when the map loads. The map still accepts the word, as
it accepts any relationship acknowledgement (ADR 0150), because refusing it at load would stop the
whole system from booting, launcher and all, over a line that only names a pair: the person
upgrading could not run `model_check` to learn which contexts cycle and through which edges. The
cycle is in the wiring, which only `model_check` reads, so the finding that names the edges and the
ways out is the clearer place, and a settled acceptance, which harms nothing, stays a warning.

**An attach acknowledges an `across`.** The Hecks domain attaches every bluebook it carries, so the
only way out of its cycles was the first one: the attaching context takes over the reactions its
upstream held. Before, `model_check` called an `across` to a context the hecksagon attaches a
contradictory relationship (a shared kernel and a customer/supplier at once). With an attach read
as a dependency with a direction, calling the attached context's commands from the attaching
context's own events keeps that direction, so the attach now acknowledges the `across` as a
`subscribe` does, and the target counts as known wherever the attaching context boots.

**The Hecks domain's four pairs are untangled.** Each reaction an attached context held to a Hecks
event is now a `translates` in the Hecks domain's hecksagon, `across` into that context's command,
with its condition, fan-out, mapping and `root` unchanged: QualityControl's mint verdict on a
rehearsal audit, Coder's submit on a finished coder run, Delivery's three main pulls after a merge
or a CI answer, and Agents' 38 reactions to a session's job read, sweep, decline, failure,
retirement, heartbeat and red episode (32 of them were policies in `agents.bluebook`). They fire
after the Hecks domain's own reactions to the same event, in the order the context declared them.
`hecks.contextmap` declares each context upstream of Hecks (conformist and customer/supplier) and
accepts no cycle; `spec/context_map_hecks_cycles_spec.rb` holds that list empty.

**Left open.** Agents' session rules (lapse an overdue review on a sweep, unstart a review whose
architect run failed) now read as the Hecks domain's wiring. The other way out, making AgentRun and
the session sweep part of Agents so the rules sit in one bluebook, is a larger change the owner may
still prefer. The cycle check reads four kinds of edge, and a plain `policy` in one bluebook on
another context's event, with no `subscribe` beside it, is none of them: Tickets'
`YieldWhenItsRunIsDeclined` on the Hecks domain's `AgentRun.AgentRunDeclined` is such a dependency
the check does not see.

**Rust.** The Rust parser has no context-map path: `hecks-parse` reads bluebooks, hecksagon
attaches, adapters and worlds, and the generated keyword table only admits `relate`'s
`accepted_findings:` argument. No Rust code builds a context map or looks for a cycle, and the
check stays in Ruby with the rest of `model_check`: its edges come from a booted registry's
hecksagons (attaches, subscriptions, translates) and bluebooks (`across`), which only the Ruby
boot assembles.
