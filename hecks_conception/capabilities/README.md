# Capabilities

Two classes of capability live in this directory : **runtime
capabilities** (51 entries — what Hecks does at runtime) and
**build-time meta-shapes** (21 entries — bluebooks that emit Rust
code at build time, processed by the specializer). They share a
naming convention but they're invoked through different paths and
play different roles.

The `_shape` suffix marks a capability as build-time codegen. A
runtime capability has no suffix.

This README is the navigation cut. The structural alternative
(nesting meta-shapes under `capabilities/_shapes/`) is filed as i160
and held — every generated `.rs` carries a `Source: …/<name>_shape/`
header that's part of the byte-identity contract, so a path move
ripples through every specializer golden and isn't worth taking
without a real reason.

## Build-time meta-shapes (21)

Each `_shape` bluebook declares the *shape of code* a generator
emits — the IR walk, the visit pattern, the rendered snippets.
The specializer reads the meta-shape, walks the conception's
domain IR, and writes a Rust file. The Rust file is checked in ;
the meta-shape + specializer reproduce it byte-for-byte (Futamura
projection ; the specializer is the partial evaluator).

Adding a new validator, parser, or query renderer in Rust starts
here, not in `hecks_life/src/`.

| Meta-shape | Emits |
|---|---|
| `autophagy_tracker_shape` | self-hosting digest tracking |
| `behaviors_fixtures_shape` | fixture loader for behavior tests |
| `behaviors_parser_shape` | `.behaviors` file parser |
| `capability_runner_shape` | per-capability runner scaffold |
| `conceiver_generator_shape` | bluebook conception generator |
| `diagnostic_validator_meta_shape` | validator-of-validators (the futamura fixed point) |
| `discover_shape` | corpus walker / boot-time discovery |
| `dispatch_query_shape` | dispatch-table query rendering |
| `dump_shape` | canonical IR dump |
| `duplicate_policy_validator_shape` | duplicate-policy detector |
| `fixtures_parser_shape` | `.fixtures` file parser |
| `hecksagon_parser_shape` | `.hecksagon` file parser |
| `heki_query_shape` | `.heki` store query rendering |
| `lifecycle_validator_shape` | lifecycle-coverage validator |
| `repository_shape` | per-aggregate repository scaffold |
| `ruby_module_shape` | Ruby kernel-bridge module emission |
| `ruby_script_shape` | Ruby kernel-bridge script emission |
| `test_purity_shape` | test-purity (sub-1s) validator |
| `validator_corpus_shape` | corpus-wide validation runner |
| `validator_shape` | per-rule validator scaffold |
| `validator_warnings_shape` | soft-warning validator scaffold |

## Runtime capabilities (51)

Each runtime capability is a bluebook (often paired with a
`.hecksagon` and `.behaviors`) that the runtime invokes when its
entry-point command fires. They group loosely by surface :

**Boot, body, mind**
`boot` · `mindstream` · `daydream` · `rem_dream` ·
`dream_interpretation` · `dream_seeding` · `surface_musing` ·
`musing_mint` · `musings` · `voice_corpus_query` ·
`wake_report` · `transparency` · `shutdown` · `self_checkin`

**Surface (CLI, terminal, statusline, dashboards)**
`cli` · `argv` · `subcommand` · `console` · `terminal` ·
`statusline` · `status_bar` · `status` · `banner` ·
`projection` · `dynamic_projection`

**Discipline + introspection**
`antibody` · `domain_hygiene` · `security` ·
`restructure` · `inbox` · `verbs`

**Domain authoring + dispatch**
`conception` · `dispatch` · `actions` · `query` · `language` ·
`runner` · `behaviors_runner` · `system_prompt_assembly`

**Storage + servers**
`storage` · `seed_loader` · `server` · `dlm_state`

**Codegen + training**
`specializer` · `rust_to_bluebook` · `glassbox_training` ·
`inventions` · `project_management`

**External surfaces**
`web_application_creation` · `web_components` · `cloudflare_deploy`

## Conventions

- Each capability owns a directory ; the bluebook has the same name.
- Pair files (`.hecksagon`, `.behaviors`, `.fixtures`) sit beside it.
- A `snippets/` subdirectory holds the verbatim Rust fragments a
  meta-shape stitches into its emitted file (specializer pattern).
- A `behaviors/` subdirectory is *test fixture data*, distinct from
  the `.behaviors` test file. Both extensions are skipped by the
  recursive bluebook walker.

## Adding a new capability

- Runtime capability : create `<name>/<name>.bluebook` with an
  entry-point command. Pair with `.hecksagon` declaring adapters,
  and `.behaviors` for test scenarios. The runtime picks it up
  through the recursive walker.
- Build-time meta-shape : create `<name>_shape/<name>_shape.bluebook`
  declaring the IR walk and snippet inventory. Add a corresponding
  specializer entry that reads the shape and writes the target Rust
  file. The byte-identity test in `hecks_life/tests/specializer_golden_test.rs`
  locks the output.
