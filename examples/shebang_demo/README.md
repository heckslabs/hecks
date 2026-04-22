# Shebang Demo — executable `.bluebook`

A minimum-viable spike proving that the `hecks-life` parser already
tolerates a leading `#!` line in a `.bluebook` file, so a Bluebook
can be chmod +x'd and invoked as a script.

## What this spike proves

- `hecks_life/src/parser.rs` silently skips any top-level line it
  doesn't recognize (the main loop only activates on `Hecks.bluebook`,
  `category`, `vision`, `aggregate`, `policy`, `fixture`). A `#!…`
  line is "unknown" and falls through — no parser change required.
- With `hecks-life` on `PATH`, running `./hello.bluebook` directly
  produces the same JSON IR as calling `hecks-life dump` on the file.
- No repurposing of `hecks-life run` (the interactive REPL) was
  needed for this spike — `dump` and `parse` already work.

## How to run

**Direct path (bypasses shebang):**

```
$ hecks_life/target/release/hecks-life dump examples/shebang_demo/hello.bluebook
$ hecks_life/target/release/hecks-life parse examples/shebang_demo/hello.bluebook
```

Both print the domain IR (JSON and tree view respectively). The
`#!/usr/bin/env hecks-life dump` line is silently ignored by the
parser.

**Shebang path (requires `hecks-life` on `PATH`):**

```
$ PATH="$(pwd)/hecks_life/target/release:$PATH" ./examples/shebang_demo/hello.bluebook
```

This invokes the binary via `/usr/bin/env hecks-life dump
<script-path>` and emits the full JSON IR.

## First obstacle

**`hecks-life` is not on `PATH` by default.** Out of the box:

```
$ ./examples/shebang_demo/hello.bluebook
env: hecks-life: No such file or directory
```

Nothing in the repo installs a binary, symlink, or wrapper into
`~/.cargo/bin`, `~/.local/bin`, `/usr/local/bin`, or `~/bin`. Users
must either:

1. Add `hecks_life/target/release` to `PATH`, or
2. Symlink `hecks_life/target/release/hecks-life` into a directory
   already on `PATH` (e.g. `ln -s
   $(pwd)/hecks_life/target/release/hecks-life ~/.local/bin/`), or
3. `cargo install --path hecks_life` to drop it into
   `~/.cargo/bin/hecks-life`.

Once `hecks-life` is resolvable by `/usr/bin/env`, the shebang works
with no further changes. macOS `env` (Darwin 24+) handles
multi-arg shebangs (`hecks-life dump`) correctly; no `env -S` needed.

## What this spike does NOT do

- No parser changes (the `#!` tolerance is incidental, not
  intentional — a follow-up may want to handle it explicitly).
- No new subcommand. `hecks-life dump` and `hecks-life parse`
  already exist.
- No repurposing of `hecks-life run` — that still drops into the
  interactive REPL. Making `run` execute a `.bluebook` as a script
  (the ergonomic end-state where the shebang just says
  `#!/usr/bin/env hecks-life`) is the follow-up.

## Forward link

See agent `a8c80e90`'s shebang runtime plan for the follow-up:
teaching `hecks-life run <file>` to execute a Bluebook non-interactively
and wiring `hecks-life` onto `PATH` as part of repo setup. This spike
is the minimal proof that the parser is already ready for it.
