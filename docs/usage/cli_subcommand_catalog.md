# CLI subcommand catalog — declared, not hardcoded

The `hecks-life` CLI used to resolve subcommands through a hardcoded
match in `main.rs`:

```rust
match command {
    "lexicon"  => run_lexicon(...),
    "speak"    => run_speak(...),
    "status"   => run_status(...),
    "terminal" => run_terminal(...),
    // ...thirty-plus more...
}
```

Adding a new subcommand meant editing Rust. Closing one meant editing
Rust. The list grew without anyone noticing because the cost was hidden
in the same file as the rest of the binary.

The catalog gate (i80, PR #482) replaces that match with a data lookup.
The list of subcommands lives in `hecks_conception/information/subcommand.heki`
as one row per command. `main.rs` consults the catalog before
dispatching.

## What the catalog row looks like

Every subcommand has a row in `subcommand.heki`. The shape is declared
in `hecks_conception/capabilities/subcommand/subcommand.bluebook`:

```ruby
aggregate "Subcommand", "One CLI subcommand declared as data" do
  identified_by :name

  attribute :name,        String
  attribute :handler,     String
  attribute :argv_shape,  ArgvShape
  attribute :description, String
  attribute :deprecated,  Boolean, default: false

  value_object "ArgvShape" do
    attribute :positional, list_of(String)
    attribute :flags,      list_of(String)
  end

  command "Register" do ... end
  command "Retire"   do ... end
end
```

A row carries the name humans type, the handler the runtime should call,
the argv shape (positional args and flag names), a one-line description
for `--help`, and a deprecation flag.

## How `main.rs` uses it

Before any aggregate work, `main.rs` calls `lookup_subcommand(name)` —
a small helper that reads `subcommand.heki` directly without booting
the full runtime. If the name resolves to a row:

- If `deprecated == true`, the CLI prints a notice and exits.
- The `handler` field names a Rust function the CLI knows how to call.
  The `print_usage` handler is the first one wired up; `help` and `--help`
  resolve to it via the catalog rather than via a hardcoded `if`.
- The argv shape will eventually drive a uniform argv parse — today
  each handler does its own parsing.

Subsequent handlers migrate one at a time. The acceptance criteria from
inbox item i80:

> main.rs shrinks to <200 LoC; every CLI subcommand is declared as a
> fixture; adding a subcommand requires zero Rust edits; the existing
> "now dispatches through hecksagon" wrappers retire alongside their
> hardcoded routes.

PR #482 stages the catalog and migrates the first token (`help`).
Each following handler becomes a token migration: declare the row,
wire the handler dispatch, delete the hardcoded route. No mega-PR.

## Adding a new subcommand

Today (with the i116 Many-form from PR #483 landed):

```sh
hecks-life aggregates/ Subcommand.Register \
  name=verify \
  handler=run_verify \
  description="Run hecks verify against the project bluebook" \
  deprecated=false
```

Or in bulk, via the Many-form:

```sh
hecks-life aggregates/ Subcommand.RegisterMany specs='[
  {"name":"verify","handler":"run_verify","description":"…","deprecated":false},
  {"name":"clean","handler":"run_clean","description":"…","deprecated":false}
]'
```

For the initial 38-row seed (when the runtime didn't yet support the
bulk form) we used a shell loop with `heki upsert --reason "initial
subcommand catalog seed"`. That out-of-band path was visible in the
audit log (38 `out-of-band:` entries) and motivated the inbox filings
i112 / i113 / i116 — the gap that became `RegisterMany`.

## Multi-domain split

The catalog work also staged `cli/`, `argv/`, and `subcommand/` as
sibling capabilities under `hecks_conception/capabilities/`. Each owns
one concern:

- `cli/` — the running CLI invocation, with `Phase` entities for
  parse / resolve / dispatch / emit
- `argv/` — argv tokenization, with `Token` entity rows
- `subcommand/` — the catalog itself

The split was the structural foundation; the catalog seed + lookup is
the first user. Future handler migrations slot in as additions to
`subcommand.heki`, not edits to `main.rs`.

## See also

- `docs/usage/audit_channel.md` — the audit log that exposed the
  hardcoded-match cost in the first place
- `docs/usage/entity_primitive.md` — Phase entity used in cli.bluebook
- `hecks_conception/capabilities/cli/cli.bluebook`
- `hecks_conception/capabilities/argv/argv.bluebook`
- `hecks_conception/capabilities/subcommand/subcommand.bluebook`
- PR #482 — the staging PR
- PR #483 — the bulk-form (i116) that retires the seed shell-loop pattern
