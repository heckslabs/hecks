# Benchmarks

`bin/bench` measures how many commands a runtime dispatches per second and how long
each one takes (p50 and p99), for the Ruby runtime on each persistence adapter and for
the native Rust binary. This page says how to run it, what it does and does not
measure, and publishes one baseline with the machine it was taken on.

It is a measurement tool, not a gate. It never fails on a slow number, and nothing in
CI runs it.

## Running it

```sh
bin/bench                                   # everything, 3 runs per target
bin/bench --targets ruby:memory,rust        # only these targets
bin/bench --domain pizzas --runs 5          # one domain, median of 5 fresh boots
bin/bench --format json --output tmp/bench.json
bin/bench --iterations 20 --warmup 5 --runs 1   # a quick smoke run
```

| flag | default | meaning |
|---|---|---|
| `--domain NAMES` | `pizzas,banking` | which example workloads to run |
| `--targets NAMES` | all five | any of `ruby:memory`, `ruby:sqlite`, `ruby:postgres`, `ruby:postgres_era`, `rust` |
| `--iterations N` | 1000 | timed cycles per run (a cycle is 4 commands) |
| `--warmup N` | 200 | cycles dispatched and discarded before timing starts |
| `--runs N` | 3 | fresh boots per target; the report shows the median and the range |
| `--rust-binary PATH` | build one | use an existing `rust` binary; needs exactly one `--domain` |
| `--format`, `--output` | `markdown` | Markdown to stdout; `--output` also writes the full JSON, per-run and per-verb |

The Rust targets run `cargo build --release --no-default-features --features <domain>` in
`rust/` first (the build is not timed). With no `cargo` on `PATH` and no `--rust-binary`,
the Rust target is skipped with a message.

### Postgres is optional

`ruby:postgres` and `ruby:postgres_era` need a reachable server and the `pg` gem. Connection
settings come from libpq's environment (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`). When
none answers, both targets are skipped with a sentence saying why, and everything else
still runs:

```text
skip ruby:postgres: no Postgres server is reachable (connection to server at "127.0.0.1", port 1 failed: Connection refused); start one, or point PGHOST, PGPORT and PGUSER at one
```

Both write to a uniquely named schema in a scratch database called `hecks_bench`, which is
created if missing (the database is left in place; each run's schema is dropped when it
finishes). They never touch the example's own database, and `ruby:postgres` does not use
the fuzzer's shared `hecks_fuzz` schema, so it is safe to run while `bin/fuzz` is running.

## What is measured

Both workloads are four commands per cycle, all valid, none refused (a refused command
aborts the run rather than being timed):

| domain | cycle |
|---|---|
| `pizzas` | `CreatePizza`, `AddTopping` twice, `Purchase` |
| `banking` | `Account.Open`, `Credit` twice, `Debit` (after one untimed `Customer.Register`) |

Every cycle names its own records, so the store grows by one aggregate per cycle. Every
runtime is driven the same way: one caller, one command at a time, each waiting for the
previous answer.

- **Ruby** boots the domain from a throwaway copy (`Fuzzing::IsolatedBoot`, the same isolation
  `bin/fuzz --adapter` uses), then times each `dispatch_flat` call in-process with the
  monotonic clock. That includes validation, guards, the aggregate update, the
  persistence write, event emission and any policy the event triggers.
- **Rust** starts the generated binary in `--serve` mode and times each round trip: write
  one JSON line to its stdin, read one JSON line back. The timer therefore includes two
  pipe crossings and the binary's own JSON parse and print. The report prints a
  **round-trip floor**, the p50 of the same round trip for a step the binary refuses at
  once, which is roughly what the pipes cost with almost no domain work behind them.

Throughput is commands divided by the wall time of the whole timed pass. `p50` and `p99`
are nearest-rank percentiles over every timed command in a run, then the median across
runs. `drift` is the p50 of the last tenth of a run over the p50 of its first tenth: above
1.0 means commands got slower as the store filled.

## What the numbers do not show

- **They do not compare the languages.** The Rust figure includes JSON parsing and printing
  and two pipe crossings that the in-process Ruby figure does not, and the Rust binary keeps
  its store in memory. The nearest Ruby row is `ruby:memory`; even that row is not the same
  work.
- **One client.** Nothing here is concurrent, so this is a service rate for a caller that
  waits, not a capacity figure. There is no network, no HTTP, no authentication.
- **Commands only.** Queries, read models, boot time, memory use, era minting, the
  Postgres-backed `rust/host` server, the WASM build and the file-backed Heki adapter are
  not measured.
- **Local Postgres.** The server is on the same machine over a local socket, with a
  configuration we did not tune. There is no network latency in the
  Postgres rows. `ruby:postgres_era` boots as a superuser under `allow_superuser`, which
  turns the era's row-level-security write fence off, so its figure leaves that cost out.
- **No caller identity.** Commands are dispatched with no role bound, the way the corpus
  replays are.
- **Garbage collection is not disabled.** A collection pause lands on whichever command was
  running, so it can be part of what p99 shows for the Ruby rows.
- **The store is small.** A run ends at a few thousand aggregates. Drift is reported, but a
  larger store is not.

## Baseline

Taken on 2026-09-26 at commit `ba9e123e` (Hecks 2.5.1), on a developer laptop that other
work was using at the same time, so read the ranges as well as the medians.

| | |
|---|---|
| CPU | Apple M3 Pro, 12 cores |
| Memory | 36 GiB |
| OS | macOS 15.7.2 (arm64) |
| Ruby | 3.3.7, YJIT off (the default) |
| Rust | rustc 1.98.0, `--release` (Cargo's default optimization level) |
| Postgres | 14.22 (Homebrew), same machine, local socket, configuration not tuned |

Warmup was 200 cycles (800 commands) and 1,000 timed cycles (4,000 commands) per run. Each
figure is the median of the runs' own figures; the range column is the slowest and fastest run's
throughput.

```sh
bin/bench --domain pizzas --runs 5 --iterations 1000 --warmup 200   # 5 runs
bin/bench --domain banking --runs 7 --iterations 1000 --warmup 200  # 7 runs
```

The two domains were run as separate invocations (the first run of both, at a
one-minute load average of 7.4 rising to 15, produced a banking half that was too noisy to
publish, so banking was repeated on its own at 5.8 rising to 6.4). Load average on a
12-core machine is a rough guide only: other processes (builds and test suites) shared the
machine throughout, so treat every figure as an upper bound on how fast a quiet machine
would be, and expect a re-run to differ.

| domain | target | commands/s | range across runs | p50 (us) | p99 (us) | drift |
|---|---|---:|---:|---:|---:|---:|
| pizzas | ruby:memory | 2,576 | 2,464 to 2,618 | 302.0 | 1,477.0 | 1.11 |
| pizzas | ruby:sqlite | 1,128 | 991 to 1,154 | 794.0 | 2,054.0 | 1.02 |
| pizzas | ruby:postgres | 782 | 671 to 816 | 1,166.0 | 2,690.0 | 0.97 |
| pizzas | ruby:postgres_era | 920 | 611 to 952 | 1,036.0 | 2,213.0 | 1.00 |
| pizzas | rust | 53,850 | 51,956 to 57,127 | 15.0 | 24.0 | 0.94 |
| banking | ruby:memory | 737 | 724 to 760 | 1,169.0 | 3,456.0 | 1.68 |
| banking | ruby:sqlite | 377 | 289 to 407 | 2,364.0 | 4,420.0 | 1.07 |
| banking | ruby:postgres | 254 | 192 to 285 | 3,672.0 | 7,725.0 | 1.06 |
| banking | ruby:postgres_era | 242 | 222 to 250 | 3,869.0 | 6,884.0 | 0.98 |
| banking | rust | 41,614 | 36,579 to 44,399 | 19.0 | 29.0 | 1.00 |

The Rust round-trip floor (p50) was 9 us for pizzas and 10 us for banking, so most of the
Rust rows' 15 to 19 us p50 is the pipe, not the domain.

### Reading it

- The Ruby runtime dispatches on the order of a few hundred to a few thousand commands per
  second on one core, at a p50 between about 0.3 ms and 4 ms depending on the domain and the
  adapter. Banking costs more per command than pizzas on every adapter.
- Against Memory's throughput, Sqlite is about 2.3 times slower on pizzas and 2.0 times on
  banking. The two Postgres adapters are about 2.8 to 3.3 times slower on pizzas and 2.9 to
  3.0 times on banking. These come from one set of runs on a busy machine, so they are a
  rough order, not a ranking to build a capacity plan on.
- `ruby:postgres_era` came out level with `ruby:postgres`: a little ahead on pizzas and a
  little behind on banking, with the ranges overlapping on both. The era adapter ran with its
  write fence off (see the caveats above), so this shows no difference between them, not that
  one is cheaper.
- The Rust binary's rows have roughly 20 to 160 times the throughput of the Ruby rows, but see
  the caveats above before comparing: its store is in memory and its figure includes the pipe.
- **Banking on Memory slows as the store grows** (drift 1.68: the last tenth of commands took
  about two thirds longer at p50 than the first tenth, over a store that reaches 1,200
  accounts counting warmup). Nothing here explains why, and no other row shows it.
- p99 is about 2 to 5 times p50 on the Ruby rows. Garbage collection is not disabled, so its
  pauses are in these figures; how much of p99 they account for was not measured.

### Reproducing it

Any machine with Ruby, `bundle install` done, and (for the Rust row) a Rust toolchain will
run `bin/bench` with the commands above. Expect different absolute numbers; the shape of the
table (Memory fastest, Sqlite next, the Postgres adapters slowest, Rust far ahead) is what to compare. The
smoke configuration in `spec/bench_spec.rb` runs the same code with a handful of iterations
so the harness does not rot; it asserts nothing about speed.

CI does not run `bin/bench`. The figures above were taken on a machine shared with heavy
unrelated work, and ranges as wide as 84 to 259 commands per second (banking, PostgresEra,
in the first attempt) were seen, so a scheduled job on a shared runner would not give a
stable enough signal to publish or gate on.
