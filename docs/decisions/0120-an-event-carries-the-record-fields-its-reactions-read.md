# An event carries the record fields its reactions read

**Status:** Proposed. Nothing is built. Date: 2026-10-17. One of three gaps a blind recovery exercise found
(see [ADR 0119](0119-a-rate-that-varies-by-kind-and-stage-is-a-declared-table.md)).

## Context

A policy's `where` reads only the triggering event's payload
([policy reference](../implemented/reference/policy.md#where)), and a command's event payload is its
arguments (`Emission#emit`). So when a reaction depends on a fact the record holds, the command that emits the
event has to take that fact as an argument it never needs, only so it lands on the event.

In the recovered stock domain, the day's ageing command `AgeOneDay` took the lot's `kind` and its
`days_left_at_close` as arguments. The command does nothing with them. Every rate policy (see ADR 0119) reads
them from `LotAged`. The caller, a `for_each` fan-out, had to copy both off each row. The command's signature
now says something false about what it needs.

## Options

1. **FRAMEWORK: `where` reads the record too.** A guard such as `where { record.kind.value == "maturing" }`
   reads the emitting record's current state. It is the smallest change for authors. But the record can move
   between the emit and the reaction (the outbox delivers later), so the same event can react differently on
   replay. That breaks the property the fuzzer leans on hardest: replaying the same steps produces
   byte-identical history.
2. **BLUEBOOK: an event declares the record fields it carries.** `emits "LotAged", carrying: [:kind, :days_left]`
   stamps those fields, as they stand after the command's own `sets`, onto the payload. The event stays a
   self-contained fact, so replays stay deterministic, and the command's arguments go back to being what it
   needs. The event's shape now includes them, and the "every emitter agrees on the shape" check applies
   unchanged.
3. **Nothing.** Keep passing record facts as arguments. It works, and it is explicit, but it misstates
   commands and makes every fan-out copy fields by hand.

## Recommendation

Option 2. Events are facts, and a reaction that reads facts off the event is the determinism model Hecks
already has. Option 1 trades that away for convenience.

## Open items

- Before or after the command's own `sets`. After is the natural reading of "the fact that happened". Before
  would need a separate word.
- How `carrying:` interacts with `with:` projections (the carried fields should be readable sources) and
  with the model_check `forwarded_payload` warning (a carried field the target does not take is refused like
  any other).
- The Rust host's event payloads, so that parity holds.
