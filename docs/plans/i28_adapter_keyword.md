# i28 — `adapter` keyword in DSL — DSL-vs-hecksagon boundary

Source: inbox `i28` (Ilya review) + plan by Agent a302c082 on 2026-04-22.

## Recommendation in one line

**Soft-reject the bluebook-level `adapter` keyword. Upgrade the existing
`external "Name"` declaration to accept an `adapter:` kwarg — the two-world
split is already crisp; the only real gap is that a command doesn't name
its adapter by symbol. Close `i28` as `recommendation-filed`; keep queued
only if Chris overrides.**

## §1 — Current state: the split is already crisp

| File | Owns |
|---|---|
| `*.bluebook` | aggregates, commands, policies, events, guards, mutations, fixtures, lifecycle |
| `*.hecksagon` | `adapter :memory/:fs/:stdout/:stdin/:shell/:env/:llm`, gates, subscriptions, capabilities, port contracts |

Verified:
- `lib/hecks/dsl/bluebook_builder.rb` has **no** `adapter` method
- `lib/hecksagon/dsl/hecksagon_builder.rb#adapter` (L74) is the only dispatcher
- `lib/hecks/runtime/boot.rb#wire_shell_adapters` (L185) — registers at boot
- `hecks_life/src/runtime/adapter_registry.rs` — Rust mirror
- `hecks_life/src/hecksagon_parser.rs` L65-95 — `adapter …` is hecksagon-only

A command reaches an adapter **implicitly** via naming — CommandBus
middleware, named shell lookup (`runtime.shell(:git_resolve_ref, …)`),
or event fan-out. The command itself says nothing structural.

### The gap Ilya named

`status.bluebook` command `GenerateReport` says in its `description`
string: "…reads every .heki store, checks mindstream via `:shell`, then
writes through the `:stdout` adapter." Prose, not symbols. Grep for
"which commands use the :llm adapter?" returns nothing structural.

The real complaint is "a command can't name its adapter" — not "adapters
aren't first-class."

## §2 — Three options evaluated

### Option A — `uses_adapter :llm` (declare use)

```ruby
command "PromptAI" do
  attribute :input, String
  attribute :output, String
  uses_adapter :llm
end
```

Pros: one-line, per-command, mirrors existing `external`.
**Cons: duplicates what `external` already does.** Without extra binding
it's documentation only.

### Option B — `adapter :llm do command ... end` (bind)

Pros: explicit binding, shorter per-command.
**Cons (rejected):**
- Collides with `HecksagonBuilder#adapter` keyword
- Forces bluebook → hecksagon evaluation order inversion
- Smuggles execution semantics into declarative side
- Multi-level parser changes (Ruby + Rust)

### Option C — Do nothing (close-as-note)

Pros: zero surface change.
Cons: `:shell` / `:llm` in descriptions stay prose.

### Option D — **Chosen**: upgrade `external` with `adapter:` kwarg

`CommandBuilder#external` already exists:
```ruby
def external(name)
  @external_systems << Structure::ExternalSystem.new(name: name)
end
```

Used by `examples/governance/*` as `external "Stripe"`. Today nominal,
no runtime hook. Upgrade to:

```ruby
command "PromptAI" do
  attribute :input, String
  attribute :output, String
  external :llm, adapter: :default, on_response: :output
end
```

- `external :llm` declares outside-the-boundary reach
- `adapter: :default` names the hecksagon adapter instance (mirrors i23's `name:`)
- `on_response:` wires response attribute back — genuine binding

### Why D

1. **Preserves split.** `external` is already bluebook-side; names a *dependency*. Different from *declaring* the adapter (hecksagon) or *binding* at runtime.
2. **Backwards compatible.** `external "Stripe"` still works.
3. **Minimal surface.** One optional kwarg, not a new keyword.
4. **Answers Ilya's critique.** Command can say "I use `:llm` adapter" structurally.
5. **Matches runtime semantics.** Adapters resolved by symbol already.
6. **No Rust churn.** `hecks_life` doesn't parse bluebooks yet; when it does, additive.

## §3 — Parser changes (Option D)

### Ruby

**`lib/hecks/dsl/command_builder.rb`** — extend signature:
```ruby
def external(name, adapter: nil, on_response: nil, on_error: nil, **opts)
  @external_systems << Structure::ExternalSystem.new(
    name:        name.to_s,
    adapter:     adapter&.to_sym,
    on_response: on_response&.to_sym,
    on_error:    on_error&.to_sym,
    options:     opts.freeze
  )
end
```

**`lib/hecks/bluebook_model/structure/external_system.rb`** — add fields, sensible defaults.

**Validation**: `Hecks.boot` time — if `adapter:` kind doesn't exist in
any hecksagon's adapters, raise `Hecks::ValidationError` (fail fast).

### Rust

No change in Stage A — `hecks_life` doesn't parse bluebooks yet. When it
does, lexer's `parse_hash_pairs` helper (L114) handles `:sym, key: val`.

## §4 — Runtime wiring (Option D)

New `lib/hecks/runtime/external_wiring.rb` (~60 LoC):

```ruby
def external_dispatch(command, aggregate)
  command.class.external_systems.each do |ext|
    next unless ext.adapter
    response = case ext.adapter
               when :shell  then shell(ext.options[:name], **command.attrs)
               when :llm    then llm(ext.options[:name] || :default, prompt: command.attrs)
               when :stdout then io(:stdout).write(template_fill(ext, aggregate))
               when :fs     then fs_read(ext.options[:path])
               else raise UnknownAdapterKind, ext.adapter
               end
    aggregate.public_send("#{ext.on_response}=", response) if ext.on_response && response
  end
rescue => e
  ext.on_error ? aggregate.emit_event(ext.on_error, error: e.message) : raise
end
```

Hook into `Runtime::CommandBus` as middleware: **after** guards pass, **before** mutations commit.

## §5 — Relationship to i23

**Sequencing:** i23 MUST land first. i23 defines `adapter :llm, name: :x`
in hecksagon; i28 (Option D) references that name from bluebook.

- i23 commit 7 exposes `runtime.llm(name, prompt:, …)`. i28's `external :llm, adapter: :default` calls `runtime.llm(:default, …)`.
- `LlmAdapter#name` field is the lookup key for `external_wiring`.
- If Option A/B ever chosen instead (overridden), i23 needs one extra hook: `LlmDispatcher#invoke_for_command(command_obj)` (~30 LoC).
- If Option C chosen (no-op), i23 entirely unchanged.

## §6 — Consumer audit

If Option D ships, bluebooks to rewrite:

| Bluebook | Commands | Adapters in prose |
|---|---|---|
| `capabilities/status/status.bluebook` | `GenerateReport` | `:shell` + `:stdout` |
| `capabilities/antibody/antibody.bluebook` | `ValidateCommit`, `ScanBranch`, `CheckStaged` | 7 git shell adapters |
| `capabilities/terminal/terminal.bluebook` | `Prompt.Speak` | `:stdout`/`:stdin` |
| `capabilities/tongue/tongue.bluebook` | `Speak` | `:shell :claude_speak` → later `:llm` |
| `aggregates/spend.bluebook` | `RecordCall` | implicit from policy |

~8 command sites across ~5 files. ~40 lines added.

If Option C, no rewrites; doc-only note in `docs/content/seam.md`.

## §7 — Commit sequence

### Option D (5 commits, ~220 LoC prod + ~180 specs)

1. `feat(bluebook-dsl): external accepts adapter:/on_response:/on_error: kwargs`
2. `feat(bluebook-dsl): ValidationError on unknown external :adapter kind`
3. `feat(runtime): ExternalWiring dispatches external :adapter`
4. `refactor(conception): migrate status + antibody bluebooks to external :<adapter>`
5. `docs: external :adapter reference + CLAUDE.md note on split`

### Option C (2 commits, rejection-with-note)

1. `docs: clarify adapters are hecksagon-only; bluebook declares intent, not wiring`
2. `inbox: close i28 as recommendation-filed (keep adapters hecksagon-only)`

## §8 — Risks

1. **DSL surface creep** — `external` already existed; kwargs not new keyword. Low.
2. **Adapter namespace collisions** — per-hecksagon scoping carries over. `external :shell` without `adapter:` reverts to nominal (fine).
3. **Nested-adapter resolution** — missing adapter in hecksagon = **fail fast at boot** (`Hecks::ValidationError`). Not runtime, not silent.
4. **Circular resolution** — non-issue for Option D (Option B would have this).
5. **Existing `external` users** — all 9 sites in `examples/governance/*` are single-arg. Backwards compatible.
6. **Split erosion** — rule: kwargs describing HOW belong in hecksagon. Watcher lint step if needed.

## §9 — Closing

The split works. Only leak: command's adapter dependency lives in
`description` string rather than structural symbol. Option D closes that
leak with one kwarg. Options A and B would "fix" it by tearing open the seam.

If Chris wants zero surface change, close `i28` with §3's rationale as
the note.

## Critical files

- `lib/hecks/dsl/command_builder.rb`
- `lib/hecks/bluebook_model/structure/external_system.rb`
- `lib/hecks/runtime/adapter_wiring.rb`
- `lib/hecksagon/dsl/hecksagon_builder.rb`
- `docs/plans/i23_llm_adapter.md` (paired)
