# A host hook calls the launcher, with facts the bluebook fills and work it detaches

**Status:** Accepted (owner, 2026-11-03). Date: 2026-11-03. Section 2 (arguments read from stdin) is built in
`Adapters::Driving::Cli::StdinSource`; sections 1 (`needs ... as:` and a fresh key) and 3 (`--detach`) are not yet.

## Context

A domain that lives inside Claude Code is driven by the host's hooks: a session starts (`SessionStart`), ends
(`SessionEnd`), a worker ends (`SubagentStop`), and the status line asks for a line. Today a client meets each
hook with a shell script of its own. Miette kept seven in `bluebook/bin`, each holding something the bluebook
cannot see: it mints a run key or a `source_ref`, stamps the time, reads the hook's JSON from stdin, picks a
field out of it, and runs the work in the background so the hook returns in time. The owner's rule is that a
domain keeps no such bucket of executables: what a script does belongs behind a port or in a launcher command.
Miette now refuses new scripts there and ratchets the rest out (`spec/bin_empty_test.rb`).

What Hecks has today covers part of it:

- The generated launcher mints a `run` key for a creating command given none, when the world says
  `launcher run_keys:` (`Adapters::Driving::LauncherOptions`; `projector/cli_projector/claims.rb`). It mints only
  the literal `run.value`, only on a creating command, only from the command line; MCP mints nothing.
- `needs` (ADR 0081) fills `now` and `today`, and only an attribute of that same name.
- `driven_by` (ADR 0103) closes the list of driving adapters (`Ruby Cli Json Mcp Web`); ADR 0169 leaves the
  next one open until it is built.

So Miette's `dream` became `bluebook/miette Session.rest!` with no change here, but `let-go`
(`Dialogue.Hold`: `key`, `held_at`), `happening` and `worker-finished` (`Kind.Report`: `source_ref`,
`occurred_at`, a summary read from the payload) and `session-end` (a night that must outlive the hook) cannot.

## Decision

The hook is a command line like any other: the host's settings call the domain's launcher, as a crontab does.
Hecks adds three generic things, and no grammar that names a host or its events.

1. **`needs` fills facts under the attribute's own name, and a fresh key is one of the facts.**
   `needs :now, as: :occurred_at` fills `occurred_at` with the moment; `needs :fresh_key, as: :source_ref` fills
   it from the `IdentityGeneration` port. Every way in (command line, MCP, a hook) then gets the same filled
   values, and replay reads the recorded arguments, as ADR 0081 already has it for `now`. The launcher's
   path-keyed `run_keys` minting stays for what it covers; nothing new is added to it.
2. **An argument may be read from the JSON on standard input, by pointer.**
   `transcript_path=@stdin:/transcript_path` or `summary=@stdin:/last_assistant_message` reads that field of the
   one JSON document the launcher is handed on stdin (RFC 6901 pointer; a missing field is an absent argument, so
   the command's own `given`s and value objects refuse it by name). No other parsing: picking a `result:` line out
   of a message stays the driving side's translation, and where that takes more than a pointer, the domain says
   so in a command that receives the whole field.
3. **`--detach` runs a command in a session of its own and returns at once.**
   The run is kept as `Operation.Run` keeps any run, so what it reported is read afterwards, not lost; a hook that
   must return within its timeout (a `SessionEnd` that sleeps a night) uses it. `settled` keeps its meaning: wait
   for the reactions, inside the detached run.

The mapping from a hook to a command stays in the host's own settings, beside the hook. A `Hook` member of
`driven_by` (with `surface: "hook"` in the audit log) is decided only if a hook must answer in the host's JSON
shape; plain standard output already reaches the session at `SessionStart`.

## Consequences

- Miette's `let-go` becomes `bluebook/miette Dialogue.hold!` with `key` and `held_at` filled by `needs`;
  `happening` and `worker-finished` become `Kind.report!` with `source_ref` and `occurred_at` filled and the summary
  read from stdin; `session-end` becomes `Session.end! --detach` with `transcript_path` from stdin. Each removal
  takes its name off Miette's ratchet.
- `needs` gains an `as:` and a `fresh_key` fact: a grammar row, the `NeedWord` change, the Rust parser's keyword
  table, and behaviors for a filled attribute under another name and for a fresh key.
- The launcher gains the `@stdin:` argument source and `--detach`, each with specs; `check_command_names` reads a
  hook's command line like any other.
- The status line and the session start (Miette's `statusline` and `wake`) are not settled here: the first wants
  a cached answer (a launcher concern, its own decision), the second a seal kept outside the journal, whose owner
  the domain must name first.

## Alternatives considered

- **A `host "Claude Code" do on "SessionEnd", dispatch: …` block in the hecksagon.** Rejected after review: it is
  grammar naming one vendor's events, while each hook already fires exactly one command; the host's settings
  already say which hook calls what.
- **Grow the launcher's `run_keys` to mint any key and the time.** Rejected: it is path-keyed, command-line only,
  and a rule kept outside the bluebook; `needs` is where a command says what the world fills for it.
- **A port per hook (`StatusLine`, `Worker`).** Rejected: the hooks drive the domain; a driven port for them points
  the dependency the wrong way, and a payload is translated on the driving side.

## Open questions

- The spelling of the stdin source (`@stdin:/path`, or `stdin.value=/path`), and whether more than one document is
  ever read.
- Whether `--detach` hands back the run's id on standard output, so a caller can follow it.
- Whether the host lets a `SessionEnd` child outlive the session, or a detached run needs the host's own
  background option instead.
