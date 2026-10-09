# Policies ask, and the hecksagon maps the port

**Status:** Proposed. Nothing is built. Date: 2026-10-09. A policy says what it needs asked (`ask :check`), and the hecksagon says which port operation answers, so a bluebook stops spelling `Aggregate::Port::Operation`.

## Context

`docs/plans/3.0/FOLLOWUP-domain-leaks.md` item 1 names the largest leak. A policy that reaches the outside writes the port operation into the bluebook:

```ruby
policy "AnalyseWhenRequested" do
  on      "ModelCheckRun.ModelCheckRequested"
  trigger ModelCheckRun::DomainRuntime::Check, with: { run: :run }
end
```

The hecksagon already declares that port (`Hecks::ModelCheckRun.port "DomainRuntime"` with `asks "Check"`, and `answers_query` for queries). So the wiring side owns the port, yet the domain side still names it, and a port rename or a second adapter edits the bluebook. The audit in the follow-up doc's 2026-10-09 status section counts 133 policy triggers naming a port operation (up from 83), 36 lifecycles starting in `requested` (up from 17) and 34 `Report` value objects (up from 15). Each new chapter copies the run protocol, so the cost grows.

## Decision

1. **DOMAIN side.** A policy gains `ask :name, with: { ... }` beside `trigger`. It names the need in the domain's words (`ask :check`), never a port. `trigger` stays for commands; `ask` is only for needs the domain cannot meet itself. The outcome policies (`on ...Answered` / `...Refused`) are unchanged.
2. **HECKSAGON side.** Nothing new to declare in the common case. The existing `asks "Check", to: ModelCheckRun` is the map: the runtime resolves `ask :check` by the event's aggregate and the ask name against the hecksagon's declared asks. If one aggregate has the same ask name on two ports, the hecksagon picks with `ask_via "Check", port: "DomainRuntime"`; otherwise boot refuses the ambiguity.
3. **Checks.** An `ask` with no matching hecksagon ask is a boot refusal and a `model_check` finding. A hecksagon ask no policy uses is a warning.
4. **Parity.** Both parsers accept `ask`; the IR policy row carries `ask: "check"` in place of the port trigger; the conformance corpus gets a fixture whose expected output includes the resolved port, so the two runtimes cannot drift.
5. **Migration in waves.** `trigger Agg::Port::Op` keeps working and is flagged by a checker warning once `ask` ships. Wave 1: the 18 triggers in `tooling.bluebook`. Wave 2: `codebase` (63). Wave 3: `deploy`, `custodian`, `tickets`, `site`, `quality_control`. A spec forbids a new port-naming trigger in a migrated file.
6. **Run protocol (items 2-3), shrinking after `ask`.**
   - DOMAIN: a `requested` lifecycle plus a settle/abandon pair exists only to record that an ask was made and came back. Once the runtime knows an `ask` is outstanding, an aggregate can declare `asks_for :check, answers: "Pass", refuses: "Flag"` and the runtime moves the record, so the `requested` state, the accept command and the abandon command stop being modelled. Whether this is a lifecycle sugar or a new word is left to a follow-up ADR.
   - DOMAIN: `Report` and `Output` attributes that hold raw subprocess text become an opaque `evidence` attribute the domain stores without parsing; the typed parts (checked, failed) stay.
   - HECKSAGON: the run key and attempt identity move to the ask, minted by the runtime, so `RunKey` leaves the domain.

## Consequences

- Wave 1 removes port names from one bluebook while the language is still small; the rest follow mechanically.
- A port can be renamed or replaced by editing only the hecksagon.
- This is a language change: grammar (`syntax.bluebook`), builder, IR, both parsers, the checker and the docs, shipped in one release the maintainer chooses.
- Until the run-protocol shrink, the `requested` aggregates stay as they are; this ADR alone changes how policies reach ports, not what is modelled.

## Alternatives considered

- **Keep `trigger` and only validate it.** Checks the leak and leaves it in the domain.
- **Name the port in the hecksagon as the only place a policy can reach, by an `on_event` binding there.** Moves the policy's logic into wiring, so a reader of the bluebook cannot see what the event causes.
- **A generic `ask` with a free-form string.** Unchecked; resolving by the declared ask name gives one boot-time check.

## Open items for the maintainer

- Is the ask name resolved by (event aggregate, name) or must it be unique across the hecksagon?
- Should `trigger` be removed after wave 3, or stay for commands only?
- Does the run-protocol shrink (decision 6) get its own ADR, or ride on this one?
- Items 4 and 5 of the follow-up (OS types as domain, Ruby-host concerns) are not touched here.
