# Duplicate Policy Validator

Two reactive policies wired to the same `(on_event, trigger_command)` pair silently double-dispatch. The runtime fires every matching policy in declaration order, so the trigger command runs once per duplicate. The validator refuses this at check time.

## The bug it catches

```ruby
Hecks.bluebook "Heart" do
  aggregate "Heart" do
    attribute :beats, Integer

    command "Beat" do
      emits "HeartBeat"
    end

    command "Tick" do
      reference_to(Heart)
      emits "Ticked"
    end
  end

  # Both policies fire on HeartBeat. Both call Tick.
  # Tick runs twice per Beat — a cascade bug with no error message.
  policy "TickOnBeat"      do; on "HeartBeat"; trigger "Tick"; end
  policy "TickOnBeatAgain" do; on "HeartBeat"; trigger "Tick"; end
end
```

## Ruby — `Hecks.validate`

The rule `Hecks::ValidationRules::Structure::DuplicatePolicies` runs automatically as part of `Hecks.validate`. It reports one error per duplicated pair, naming every colliding policy and the total count.

```
ValidationError:
  2 policies share (event: HeartBeat, trigger: Tick) — the trigger fires
  once per matching policy, so Tick will run 2 times per HeartBeat event.
  Policies: TickOnBeat, TickOnBeatAgain
  (TickOnBeat in Heart; TickOnBeatAgain in Heart).
    Fix: Delete the duplicates or collapse them into one policy. If fan-out
         is intentional, give each policy a distinct trigger command.
```

## Rust — `hecks-life check-duplicate-policies`

The `hecks-life` binary exposes a standalone subcommand that walks the IR and exits non-zero on any duplicated pair:

```
$ hecks-life check-duplicate-policies heart.bluebook
Checking Heart (heart.bluebook)

Duplicate policies:
  ✗ TickOnBeat, TickOnBeatAgain — 2 policies share (on: "HeartBeat", trigger: "Tick") — the trigger fires once per matching policy, so Tick will run 2 times per HeartBeat event. Delete the duplicates or collapse them into one policy.

1 error(s)
FAIL — heart.bluebook has duplicate policies
```

Exit codes:

- `0` — no duplicate (event, trigger) pairs
- `1` — at least one pair shared by >1 policy

## What is not a duplicate

- **Same event, different triggers** (legitimate fan-out):
  ```ruby
  policy "KitchenOnPlaced" do; on "OrderPlaced"; trigger "NotifyKitchen"; end
  policy "ChargeOnPlaced"  do; on "OrderPlaced"; trigger "ChargeCard"; end
  ```
- **Different events, same trigger** (same reaction from multiple sources):
  ```ruby
  policy "EchoOnRang"   do; on "Rang";   trigger "Echo"; end
  policy "EchoOnChimed" do; on "Chimed"; trigger "Echo"; end
  ```
- **Cross-domain wiring** — domain-level policies keyed with `@target_domain` do not collide with same-domain `(event, trigger)` pairs.

## Fix options

1. **Delete the duplicates** — one policy is almost always a leftover from renaming or copy-paste.
2. **Collapse into one policy** — if the intent is fan-out, one subscriber handling all downstream nerves in one pass is cleaner than N policies sharing a trigger.
3. **Give each policy a distinct trigger command** — if two subsystems genuinely need separate reactions, model them as separate commands.
