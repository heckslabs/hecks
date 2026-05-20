---
ref: i656
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Chris: file this one)
category: framework / runtime / executable_bluebook / autophagy
value: 'Executable bluebook flavour (B) — `storehouse compile foo.bluebook -o foo` produces a single self-contained binary with the bluebook bytes baked in, runs `./foo Aggregate.Command k=v` like storehouse but with no external runtime on PATH. Heavy counterpart to i649 (shebang flavour). Closes the autophagy loop : the runtime carries the bluebook the way a Go static binary carries its code.'
links:
  - i649-executable-bluebook-shebang.md
  - i558.md
---

# i650 - Executable bluebook (compile-to-binary flavour, flavour B)

## Chris's seed (verbatim)

> a new subcommand `hecks-life compile foo.bluebook -o foo` produces
> a single self-contained binary with foo.bluebook baked in. run
> `./foo Aggregate.Command k=v` and the binary dispatches like
> storehouse but with the bluebook embedded. like Go static binaries
> or `pkg` for Node.

Naming convention : `storehouse compile`, not `hecks-life compile`
(`storehouse` is the canonical CLI per the 2026-05-13 conventions ;
`hecks-life` was retired).

## Why both flavours

Flavour (A) — `i649` — is light : a `.bluebook` with a shebang runs
through `storehouse` already on PATH. Idiomatic, no build step,
but the user must install the runtime first.

Flavour (B) — this card — is heavy : a single binary, no
prerequisite. The user gets a portable artefact they can ship,
sign, drop on a server, hand to someone else. It is the autophagy
vision concretely : the runtime carries the bluebook the way a Go
static binary carries its code.

Both flavours dispatch through the same kernel ; (B) is (A) with
the file-read replaced by an `include_bytes!` read. The two cards
together describe one image with two halves.

## Shape (the compile contract)

```sh
storehouse compile foo.bluebook -o foo
# → produces ./foo, a single self-contained binary
./foo                       # → dispatches the bluebook's entrypoint
./foo Aggregate.Command k=v # → dispatches an explicit command
./foo --help                # → prints the bluebook's vision + commands
```

### Subcommand surface

```
storehouse compile <bluebook-path> [-o <output-name>]
                                   [--with-hecksagon <hecksagon-path>]
                                   [--release | --debug]
                                   [--target <triple>]
```

- `<bluebook-path>` — required. The `.bluebook` to embed.
- `-o <output>` — optional. Defaults to the bluebook's stem.
- `--with-hecksagon <path>` — optional. Overrides the default
  sibling-discovery (`<stem>.hecksagon`). Multiple hecksagons can
  be embedded if the bluebook spans them (rare ; design TBD).
- `--release` / `--debug` — passthrough to the underlying cargo
  build. Default `--release`.
- `--target <triple>` — passthrough to cargo for cross-compile.

The implementation is a `cargo build` against a templated crate
that includes the bluebook bytes :

```rust
// generated src/main.rs in the templated crate :
const EMBEDDED_BLUEBOOK: &[u8] = include_bytes!("/abs/path/to/foo.bluebook");
const EMBEDDED_HECKSAGON: &[u8] = include_bytes!("/abs/path/to/foo.hecksagon"); // or empty

fn main() {
    let bluebook = std::str::from_utf8(EMBEDDED_BLUEBOOK).unwrap();
    let hecksagon = std::str::from_utf8(EMBEDDED_HECKSAGON).unwrap_or("");
    storehouse::run::run_embedded(bluebook, hecksagon, std::env::args().collect());
}
```

The runtime, parser, registry, dispatcher all link from
`storehouse` as a library crate. The compiled binary IS storehouse
plus a tiny `main.rs` that hands the embedded bytes to it.

## What needs to land in the runtime first

The current `run::run_script` takes a `path: &str` and calls
`std::fs::read_to_string`. The new entry point is a sibling that
takes the bytes directly :

```rust
// proposed addition to rust/src/run.rs
pub fn run_embedded(bluebook: &str, hecksagon: &str, args: Vec<String>) -> i32 {
    let domain = parser::parse(bluebook);
    let hex = if hecksagon.is_empty() {
        Hecksagon::default()
    } else {
        hecksagon_parser::parse(hecksagon)
    };
    // ... rest mirrors run_script after load_script returns
}
```

The capability detectors (`is_stdin_loop_capability`,
`is_status_report_capability`, `is_boot_capability`, ...) read the
runtime + registry, not the path, so they already work against the
embedded bytes unchanged.

One reshaping is needed : `load_script` currently lives next to
the disk read. Extract the post-read body into a `load_from_bytes`
helper that `run_script` and `run_embedded` both call. That's the
contract.

## Dependency chain (what gets linked into the binary)

The compiled binary must carry :

| Chapter / module | Why |
|---|---|
| `parser`, `hecksagon_parser`, `world_parser` | parse the embedded bluebook |
| `ir`, `hecksagon_ir`, `world_ir` | the parsed shape |
| `runtime` (full) | dispatch, registry, adapters, middleware |
| `run` (without disk-reading paths) | the dispatch orchestrator |
| `heki` (only if the embedded bluebook needs `.heki` persistence) | optional ; can be feature-gated |
| `validator`, `behaviors_*`, `dump`, `specializer` | NOT needed at runtime — dev-only |

A `--profile embedded` Cargo profile + feature flags can excise the
dev-only chapters from the compiled binary. Realistic binary size
target : 5-15 MB for a typical bluebook, with `strip` + LTO.

## Heki state, side effects, and the runtime gap

The hardest open question. A compiled `./foo` has no obvious place
to put `.heki` files. Today `infer_data_dir` walks the bluebook's
parent directory ; the compiled binary has no bluebook on disk.

Three options, ordered by simplicity :

1. **`$HOME/.hecks/<binary-stem>/`** — the binary derives its own
   state directory from its own name. Predictable, isolated. The
   pattern most CLIs use (`~/.cache/foo`, `~/.local/share/foo`).
2. **`$PWD/.hecks/`** — state lives where the binary is invoked
   from. Matches `git`'s `.git/` discovery model. Best for
   per-project bluebooks ; worst for daemons.
3. **`$HECKS_INFO` env var, then fallback to (1)** — explicit
   wins. Mirrors the canonical `heki::resolve_info_dir` precedence
   already in run.rs. Probably the right answer.

Option 3 is the proposal.

## Dynamic adapter loading (the runtime gap)

Bluebooks today reach beyond their declared adapters in two ways :

- `:exec` adapter shelling out to scripts that aren't bluebook-
  resident (`bin/process_health_sweep`, etc.).
- `:llm` adapter binding to external providers (Anthropic, Ollama)
  whose credentials live in env.

A compiled binary can carry the `:exec` *contract* (the path to
the script) but not the script itself unless it's also embedded.
For v1 the proposal is :

- Embed-only the bluebook + companion hecksagon.
- The :exec adapter still resolves the script from the filesystem
  at runtime — same as today. Document this as a deployment
  consideration : the binary is portable, but :exec scripts are
  not (yet).
- :llm adapter reads credentials from env as today.

A later card can layer asset-embedding (a la Go's `embed.FS`) onto
this base.

## Relationship to autophagy

`lib/hecks/autophagy/` was deleted in Phase E (the great Ruby
purge). The intent — "the runtime digests itself into a binary" —
survives in spirit and finds its concrete shape here. Where
autophagy compiled the Ruby runtime into a binary, executable-
bluebook (B) compiles the Rust runtime + an embedded bluebook into
a binary. Same arc, different stack, post-purge.

The compile path may eventually fold in the specializer (i39) so
the compiled binary specialises its own dispatch to the embedded
bluebook's shape. That's the second Futamura projection applied to
the executable-bluebook line. Out of scope for v1.

## Signing / verification (open)

A compiled binary is a deployment artefact. Eventually we want :

- Embedded bluebook hash, surfaced by `./foo --bluebook-hash`.
- Optional signature over the embedded bluebook bytes.
- `storehouse verify foo` that reads the embedded hash and re-runs
  the validators against the embedded bluebook to prove nothing
  was tampered with post-compile.

Not v1. Filed here because the substrate decisions (where to put
the hash in the binary, whether to mmap the embedded slice or copy
it) want to keep this future open.

## Open questions (collected)

1. Subcommand name : `storehouse compile` (vs `storehouse pack` or
   `storehouse build`). `compile` is the most accurate ; ship it.
2. Multi-bluebook compile : if a bluebook depends on other
   bluebooks (world/composition), do we embed all of them or
   require flattening first? Probably the latter ; `storehouse
   flatten` is its own card.
3. Reproducible builds : embed timestamps and the storehouse
   version, or strip them? Reproducible by default. Surface the
   storehouse version through a separate flag.
4. WASM target : the runtime is already wasm-safe per i630. A
   `--target wasm32-wasi` flag would compile to a wasm binary. v1
   ships native ; wasm follows.
5. State directory for the embedded binary (Option 3 above) — the
   one decision that has user-visible consequences and wants a
   pre-decision before implementation.
6. How does `./foo --help` discover the bluebook's command list?
   Walk the parsed domain, print commands grouped by aggregate.
   Standard.

## Sequencing (when this lands)

Not tonight. The sequencing arc :

1. Land i649 (the shebang flavour) — DONE in this push.
2. Extract `load_from_bytes` in `run.rs` so the disk read isn't
   load-bearing for the dispatch path. Small refactor, no shape
   change.
3. Template a tiny `storehouse-bin-template` crate that
   `include_bytes!`'s the bluebook + hecksagon and calls
   `run_embedded`.
4. Implement `storehouse compile` as a subcommand in `main.rs`
   that runs cargo against the template with the bluebook path
   wired in.
5. Decide the state-dir question (Option 3 above) before any
   binary touches `.heki` persistence.
6. Ship a `examples/executable/hello-compiled` example showing
   the compile + run.

Each step is a card. This is the umbrella.

## Acceptance for this card (design, not implementation)

- [x] Card filed at i650 (next available after i648).
- [x] Subcommand contract named (`storehouse compile`).
- [x] Embed mechanism named (`include_bytes!` + templated crate +
  `run_embedded` entry point).
- [x] Dependency chain mapped (parser, ir, runtime, run.rs ; not
  validator / behaviors / specializer).
- [x] Relationship to autophagy named (Phase E legacy ; this is
  the post-purge successor).
- [x] Open questions surfaced (state dir, signing, multi-bluebook,
  WASM, --help).
- [x] Sibling card cross-linked (i649 shebang flavour).
- [ ] Implementation cards filed when the umbrella moves out of
  designed.
