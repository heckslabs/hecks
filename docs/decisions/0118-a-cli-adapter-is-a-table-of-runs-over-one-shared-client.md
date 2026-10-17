# A Cli adapter is a table of runs over one shared client

**Status:** Proposed. Built: decisions 1 and 2, the shared client and `Shell` on top of it. Decisions 3 to 8 are not built.
Date: 2026-10-17. It is step 2 of the build order in `docs/brownfield/bubble-spread.html` on the `brownfield-adapters`
branch ("The plumbing"): transport clients and the data-driven adapter format, Cli first. Its first consumer is meant to be
REA (`morluto/rea`, the `rea-agents` CLI), as the adapter a bubble uses before Watch, when the legacy system's code is not
readable either.

## Context

The brownfield plan says each prewritten adapter is a thin wrapper over a shared client, and that Cli "builds on the existing
Shell adapter." Before this ADR:

- `Adapters::Shell#capture` ran argv through `Open3.capture3`. It had no timeout, held all output in memory, and started the
  child in this process's group.
- `Adapters::ProcessPool` already did, for its one caller, the two things Shell lacked: its own process group with signals
  passed on, and output to a file "so a child that writes a lot never blocks."
- `Adapters::ClaudeCode` re-implements spawn, timeout and JSON unwrap for itself.
- `Runtime::AdapterLookup.call` builds a domain-port adapter with a bare `.new`. Persistence adapters receive world settings
  through `RepositoryFactory.adapter_settings`; ask adapters receive none, so `Git` reads `EMBRYONAUT_BLUEBOOKS_SRC` from the
  environment.
- The `.adapter` language admits `port`, `field` (with `default:`, ADR 0106) and `secret`. It cannot say what an adapter does,
  so every adapter's behaviour is Ruby, and Rust cannot read it.

REA's CLI states its contract (`docs/cli.md`, "Output and exit status"): `0` completed, possibly with partial evidence; `1`
failed, with a structured error `{code, category, message, retryable, remediation}`; `128+N` a signal, which it may handle
itself and report as `130` or `143`. Its Evidence for one application can exceed 300 MB, and every result that carries text
from the analysed target is marked `untrusted_content`. It has no authorization of its own; its tool annotations are hints.

## Decision

Every decision says which side it is on.

1. **FRAMEWORK, built: one Cli transport client, `Hecks::Transport::Cli`.** `Client#run` takes argv, never a shell string,
   and an effect, and yields a `Reply` whose stdout is a file that lives until the block returns (`Reply#keep` moves it out).
   `Child` runs the program in its own process group with stdin from `/dev/null` and output to files. A timeout, an interrupt
   or any raise while waiting sends `TERM` to the group, waits two seconds, then sends `KILL` to the group regardless: a
   leader that exits cleanly on `TERM` can leave children running, and the group outlives its leader. The errors are
   `NotInstalled` and `TimedOut` (both `Unavailable`, worth retrying) and `ReadOnly`.
2. **FRAMEWORK, built: `Shell` keeps its interface and runs through the client.** `Shell#capture` still answers `Result(out,
   err, status)`, still answers a missing program as status 127 rather than raising, and still waits as long as the program
   runs: its client has no timeout. It gains the process group, so an interrupt stops what it started. Because a shell cannot
   know what a program does, its runs declare the widest effect. `Git` and every Custodian adapter built on `Shell` change
   with it.
3. **ADAPTER LANGUAGE: a `.adapter` file may declare `runs` rows.** A row names the ask it answers, its argv with `{field}`
   placeholders read from the record's held state, its effect, whether its output is kept, whether it is untrusted, and which
   event fields it answers from where. An adapter class is built from the rows, so `AdapterLookup` finds it like any other.
   Being data, the rows are what both runtimes read; until `rust/host` reads them, a Cli adapter is a Ruby-only parity gap,
   as the plan's escape hatch allows.
4. **ADAPTER LANGUAGE: every row declares an effect: `reads`, `writes` or `executes_foreign_code`.** The client refuses a
   row that is not `reads` when the world is read-only (built in decision 1), which makes the plan's "read-only is a setting,
   not a promise" a check at the call. The model check should also refuse a read-only world bound to an adapter none of whose
   rows read.
5. **ADAPTER LANGUAGE: an untrusted row answers only from the file, never from its contents.** Its answers may be the output's
   path, SHA-256 or size (`Reply#out_path`, `#sha256`, `#bytes`), and an adapter declaring otherwise is refused when it is
   built. Target-derived text then never enters an event payload, a projection or a prompt; it stays in the file, which is
   ADR 0101 item 2's opaque `evidence` in practice.
6. **FRAMEWORK: a placeholder that fills a whole argv element may not start with `-`.** Argv removes shell injection but not
   argument injection: a held `target` of `--provider=evil` would otherwise become a flag.
7. **FRAMEWORK: `AdapterLookup` hands an ask adapter its world settings.** It builds with `new(settings:)` when the
   constructor accepts the keyword. `Shell`, `Git` and `ScriptRunner` already accept `settings: {}` and ignore it. This is the
   plan's step 1 ("typed world settings"), and every prewritten adapter needs it to be configured per environment.
8. **STOREHOUSE: an effect is a capability.** A row's effect becomes the token its ask requires (`reverse.reads`,
   `reverse.executes_foreign_code`), so a driver reaching a Cli adapter is admitted by the same deny-by-default chokepoint as
   any command, and REA's missing authorization is supplied by Hecks.

## Worked example: REA

The port, in a hecksagon. The chapter never names REA:

```ruby
Investigation::Investigation.port "Reverse" do
  asks "InspectJavascriptApp", to: Investigation do
    attribute :target, TargetPath
    answers "Inspected"
    refuses "InspectionRefused"
  end
end
```

The adapter, in the proposed `runs` grammar:

```ruby
Hecks.adapter "Rea" do
  port "Reverse"
  transport "Cli", program: "rea"
  field :timeout,    default: "300"
  field :read_only,  default: "true"
  field :output_dir, default: "data/evidence/{storage_name}"

  runs "InspectJavascriptApp", effect: :reads, keep: true, untrusted: true do
    argv "analyze-javascript-application", "{target}", "--json"
    answers evidence_path: :output_path, evidence_digest: :output_sha256
  end

  failure :structured_json # rea's {code, category, message, retryable, remediation}
end
```

An ask that answers becomes `Inspected` with the path and digest of the kept Evidence; any refusal becomes
`InspectionRefused` with REA's own message. A summary of the Evidence is a second, separate step (REA's
`inspect-analysis-view`), reviewed before anything reads it into a model, because it is still target-derived text.

## Consequences

- `spec/transport/cli_client_spec.rb` pins the client. Its group examples were checked by mutation: without the stop on an
  unfinished wait both fail, and without the final group `KILL` the example whose child ignores `TERM` fails.
- `Shell`'s six examples, and the 494 examples of every spec that names `Shell`, `Git`, `SiteToolchain`, `DeployToolchain`
  or a codebase adapter, pass unchanged.
- A `Shell` child no longer shares the terminal's process group, so a terminal `SIGINT` reaches it through Ruby's
  `Interrupt` and the client's stop, not directly. A child that read the terminal would notice; none does, since `Shell`
  has always given it no input.

## Open items

- The `runs` grammar: its words, and whether `transport "Cli"` is a word or implied by `runs`.
- Where a failure reader lives: a closed set of named readers (`:structured_json`) or a Ruby escape hatch.
- Whether `Unavailable` should carry `retryable` from the program's own error, so the outbox retries only what the program
  calls retryable.
- Retention of kept output: who deletes Evidence files, and when. Probably a custodian.
- Long runs still block dispatch; a native REA analysis can take minutes. That waits on ADR 0101.
- The Rust host reading `runs` rows, and the recorded-response fixtures the plan asks for in both runtimes.
- `ClaudeCode` moving onto the client.
