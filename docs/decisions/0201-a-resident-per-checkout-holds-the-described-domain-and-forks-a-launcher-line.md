# A resident per checkout holds the described domain and forks a launcher line

**Status:** Accepted. The owner chose the resident on 2026-11-09 over leaving boots as they are, and it was built the
same day (`lib/hecks/adapters/driving/resident/`); "As built" below records where the build differs from the decision and
what it measured. Date: 2026-11-09.
Builds on [0089](0089-the-mcp-door-gets-a-commands-scope-and-stays-booted.md), whose restricted server already keeps a domain booted.
The figures in the Context and the spike were measured before the build; those of the build are under "As built".

## Context

Every `hecks` line is a fresh Ruby process that loads the gem, loads the declarations of the Hecks domain and every
bluebook it attaches, binds adapters, runs the line and exits. The usage log (`~/.cache/hecks/usage.jsonl`) holds
between 2,300 and 19,000 such runs a day over 2026-11-02 to 2026-11-09, about 17,000 on a busy day. Almost all of
them do 20 to 50 ms of work after the boot.

| Step of one boot (warm caches, macOS arm64, Ruby 3.3.7, the Hecks domain) | Main on 2026-11-08 | With the boot-time branch |
|---|---|---|
| `bundler/setup` | 0.15 s | 0.15 s |
| `require "hecks"` | 0.33 s | 0.17 s |
| `Hecks.describe` | 0 s (lazy) | 0 s (lazy) |
| first use of the registry, which loads every declaration | 1.9 s | 1.0 s |
| `Hecks.boot_described` and the command | 0.1 s | 0.1 s |
| whole `hecks RedFlag.status` | 2.8 s | 1.3 s |
| `hecks --help`, answered from the usage cache | 0.6 s | 0.3 s |
| the same after an edit under `lib/` (verdict cache cold) | 12 s | 9 s |

At 17,000 runs a day the 2.8 s is about 13 CPU-hours a day, and the 1.3 s is about 6. A process spends about a
fifth of the load in garbage collection and holds 190 MB. The pipeline analysis of 2026-11-09
(`~/.claude/plans/write-this-up-as-wondrous-babbage.md`) removes the boots that Hecks itself caused (the board, the
dispatcher, the retry loop). What remains is every agent session's own `exe/hecks` call and every human one, each
still paying the whole boot for 20 to 50 ms of work.

ADR 0089 measured the other way: a restricted server that stays booted answers a call in under 10 ms. That is the
floor the launcher can approach if the declarations load once.

## The spike

The directive was to answer two questions with measurements. The measuring scripts were refused by the session's
permissions, so the first is answered by reading the code and the second is argued from the code and the figures above.

**Can the described registry be written to a file and read back?** Not as it stands.

- `Hecks.describe` returns a `Loader::Described` (`lib/hecks/runtime/loader/described.rb`) that holds its directory
  and the block that loads. The registry it builds on first use holds mutexes (`@saga_mutex` and
  `@saga_persistence_mutex` in `lib/hecks/runtime/registry.rb`), which `Marshal` refuses, so the registry as an
  object cannot be dumped.
- The load does more than build plain data. It seeds the verdict cache, builds the grammar registry, evaluates
  declarations with a `const_missing` resolver installed (`Bluebook::DSL::ConstShim`), attaches the bluebooks a
  hecksagon names and registers adapters. A file read would have to rebuild all of that or prove it unnecessary.
- The prior art is narrower: the syntax-boot cache (`lib/hecks/bluebook/meta_validator/syntax_boot/disk_cache.rb`)
  stores plain string rows with `Marshal` under a private cache directory, and the usage cache stores a printed
  answer. Both keep the output of a pure step, not a live registry.
- A snapshot of the declaration IR alone might dump, but whether the rest of the load can be rebuilt from it is a
  project of its own, with no figure for the saving until it exists. This ADR does not take it.

**Can a process hold the loaded declarations and run each line in a fork?** It can, subject to the hazards below.
The cost per request is a fork, the post-describe path (about 0.1 s in the table, mostly adapter binding that is
not needed for a read) and the exit. Not measured here: the fork's own time, and the resident's memory growth over a
day. The build's acceptance test stands in for the first (a warm `hecks RedFlag.status` under 0.15 s).

## Decision

1. **A resident per checkout holds the loaded declarations and forks for each line.** The launcher, before
   `bundler/setup`, looks for a socket under `Hecks::CacheDir` (`lib/hecks/cache_dir.rb`) named for the checkout's real
   path. A resident that answers gets argv, the working directory, the environment and the standard input, and relays
   standard output, standard error and the exit status, so a caller cannot tell it from a cold launcher. With no
   answer the launcher boots as it does today and may start a resident for the next call.
2. **The resident loads the declarations and binds nothing.** It does `Hecks.describe` and touches the registry,
   which is the 1.0 s, and opens no store, runs no adapter and takes no lock. For each request it forks. The child
   does what the launcher does from `Hecks.boot_described` on: it binds adapters for its own line, opens the stores
   its line names, runs, and exits. Each line therefore sees a fresh runtime, as today. `exit`, `abort`,
   `Dir.chdir`, `ENV` and `Interrupt` stay inside the child.
3. **The resident keys itself to the code and the domain.** It records a fingerprint of `lib/`, the domain's
   declaration files, `Hecks::VERSION` and `HECKS_ENVIRONMENT`. Taking that digest costs about 80 ms
   (`UsageCache.entry_path` measured 82 ms, `VerdictCache.language_digest` 37 ms), too much for each call, so the
   resident checks a cheap listing of path, size and modification time and digests only when the listing changed.
   When the fingerprint moves, it finishes the requests in flight and exits, and the next launcher starts a new one.
   It also exits after an idle period, set in the world, so a checkout nobody is using holds no memory.
4. **Some lines never go through it.** `console`, `interview`, `init` and a line given `--stream` need the terminal
   or run until interrupted, so the launcher runs them itself. The launcher's top-level changes to `ARGV` and `ENV`
   (`MEMORY_COMMANDS`, the ledger route) move into the request path in the template
   (`lib/hecks/tools/project_cli/templates.rb`), because a resident has no per-line top level.
5. **The resident is a cache, never a source of truth.** Killing it loses nothing and costs the next call one cold
   boot. It holds no record, writes no file but its socket and its pid, and its socket sits in a directory only the
   user can write, as `CacheDir` already requires of the syntax-boot cache that is read back with `Marshal.load`.
6. **The servers a session starts load late.** The two Ruby processes `.mcp.json` starts per session
   (`lib/hecks/tools/mcp.rb`, `lib/hecks/adapters/driving/mcp_scope.rb`) keep their protocols but load the framework
   on the first tool call, so a session's idle cost falls from two full loads to two thin processes. The first design
   made them clients of the resident; "As built" says why they are not.

## Consequences

- A warm launcher line should cost the fork and the line's own work, a few tens of milliseconds, against 1.3 s. The
  build proves it with the measurement this ADR lacks, on the lines of the client launcher smoke spec.
- Memory moves from many short processes to one resident of about 200 MB per active checkout, plus its forks while
  they run. Agent worktrees each get their own resident, so a dozen sessions could hold a dozen. The idle exit and a
  ceiling on the number of residents (the oldest idle one exits first) bound it.
- Code that reads `ARGV` or `ENV` when its file loads is wrong in a resident, since the resident loads once and
  serves many lines. The launcher template is the known case; the build searches `lib/` for others.
- A change to anything under `lib/` makes the next call cold (9 s on the boot-time branch) and starts a new resident.
  An agent that edits `lib/` all day pays that after each edit and then recovers; the telemetry from W0 of the plan
  (`cold` and `boot_ms` in the usage log) says how often.
- A resident that holds an open handle across the fork would share it with every child. Decision 2 forbids it, and a
  spec makes the resident refuse to serve while a store or lock is open in it.
- Specs must never reach a developer's resident. The socket directory follows `HECKS_CACHE_DIR`, which the specs
  already point at a temporary directory, and the live-state guard fails a spec that opens the live socket.

## Alternatives considered

- **Serialize the loaded declarations and read them at boot.** It would need no resident, but the registry cannot be
  dumped as it is (it holds mutexes) and the load has effects beyond data, so it means redesigning what the load
  returns. Worth revisiting for the part that is pure data, as a way to make the resident's own start cheaper.
- **Threads in one process instead of forks.** It would remove the fork, but the runtime calls `exit` and `abort`,
  the spec runner changes directory, Memory persistence would be shared between lines, and one stuck command would
  hold every caller. A fork gives each line the isolation it has today.
- **Make the restricted MCP server the one resident.** ADR 0089's server already stays booted, and sessions already
  start one. But it serves a closed list of typed commands and checks arguments by name, so it is the right door for
  an agent and the wrong one for an arbitrary launcher line. Decision 6 makes it a client of the resident instead.
- **Keep only the boot-time work.** The load and the digest are already cut by the word-gate index, the shared
  emitter index and the lazy loads, which halved the boot. What is left is spread over the evaluation of every
  attached bluebook and the collector, with no single step to remove.
- **A snapshot of the booted domain under `prebuilt/`.** The gem could ship it, as `CacheDir.prebuilt` allows for
  other caches. It shares the first alternative's obstacle and adds a build step on every change to `lib/`.

## As built

The build is in `lib/hecks/adapters/driving/resident/`: `client.rb` (what a launcher runs first), `server.rb` with
`loading.rb` and `serving.rb` (the resident), `worker.rb` (the forked child), `fingerprint.rb`, `described_cache.rb`,
`wire.rb` and `paths.rb`. Decisions 1 to 5 stand. Where the build differs from the text above or adds to it:

- **The child runs the launcher script itself.** Decision 2 has the child do "what the launcher does from
  `Hecks.boot_described` on". The build instead `load`s the real `exe/hecks` in the child, with `Hecks.describe`
  answering from the resident's cache. The launcher's own top level then handles the line (the Memory defaults, the
  ledger route, usage, streaming, the usage log), so none of it is written twice and the cold and warm paths cannot
  drift. The cost is a re-parse of a small file. Decision 4's "move the top-level state into the request path" is
  therefore not needed.
- **The caller's streams are passed, not copied.** The client sends its standard input, output and error over the
  socket as file descriptors, and the child reopens its own on them. A terminal stays a terminal, a pipe stays a
  pipe, and the resident never sits between a caller and its output. The exit status comes back as one line. When
  the caller's end of the socket closes before the line is done, the resident interrupts the child.
- **No `Marshal`, no JSON on the socket.** The request is the argument list, the environment, the directory and the
  script as NUL-ended fields, and a reply is one word. The client may not load `json` before `bundler/setup` (it
  would not be the version the Gemfile pins), and nothing the other end sends is ever deserialized.
- **Residents are kept apart by the cache directory.** The socket directory follows `HECKS_CACHE_DIR` as the help
  cache does, and `spec_helper` sets `HECKS_NO_RESIDENT=1`, so a launcher a spec starts neither uses nor leaves a
  resident. The decision's live-state guard for a spec that opens the live socket is not needed: the specs cannot
  reach it. The socket path must fit the system's limit (103 bytes on macOS); a longer one is not used and the
  launcher boots on its own, which a long temporary directory name will do.
- **The resident serves only a line made as it was loaded.** A request whose `HOME`, `XDG_CACHE_HOME`,
  `BUNDLE_GEMFILE`, `RUBYOPT`, `RUBYLIB`, `HECKS_NO_USAGE_CACHE` or `HECKS_ENGINE` differs from the resident's own is
  answered by the launcher itself, because the code read those when it loaded. `HECKS_ENVIRONMENT` is not one of
  them: each environment is its own cached load.
- **It learns what it lacked.** A child that needs a domain or environment the resident has not loaded builds it as a
  cold launcher would, and names it and the Ruby files it loaded; the resident loads them after the reply, so the
  next child finds them ready. Loading output a cold launcher prints (the worktree-overlay warning, for one) is
  captured once and printed by a child the first time it asks for the registry, as a cold launcher prints it.
- **Cheap to fork, cheap to leave.** Three costs a child inherited were found by measuring and removed. The resident
  writes the verdicts its load judged (a child had written them again at its own exit, 150 ms a line), keeps the
  usage cache's digest of the declaration files (80 ms a line), and runs `Process.warmup` so a child's garbage
  collections leave the shared pages alone. A child ends by flushing its output, reporting an uncaught error,
  closing its temporary files and leaving without Ruby's teardown of the shared heap, after every other exit
  handler has run.
- **The ceiling on residents refuses, it does not evict.** Decision 3's "the oldest idle one exits first" is not
  built: a resident that finds `max_residents` others standing exits at once and its launcher boots on its own. Both
  numbers are the Hecks world's `resident` line (`idle_seconds` 600, `max_residents` 8).
- **A resident leaves when its checkout does.** Once a second, when no line is waiting, it checks that its checkout
  directory and its own socket still exist (`Server#orphaned?`, with a stat seam for specs) and retires when either
  is gone: a worktree that was retired, a temporary directory that was removed, or a cache that was cleared. It no
  longer waits out the idle time for a checkout nobody has.
- **The servers a session starts load late, and are not clients (decision 6 as built).**
  - **Late loading.** Both servers answer `initialize`, `ping` and `tools/list` without the framework and load it on
    the first tool call (`Mcp::Loading#framework!`, `QueryIrMcp.load_queries!`). Two small files make that possible:
    `storehouse/confinement.rb` (the boot root and the path check `McpScope` needs) and `storehouse/source_tags.rb`
    (the one list the tool definitions name). The stdio guard and the `HECKS_SERVER_*` checks run before anything is
    written, as before. A commands server loads the framework at `tools/list`, because its command guide is read from
    a booted domain, and a tool its scope refuses is refused without loading it. `spec/mcp_light_server_spec.rb` holds
    the replies to goldens written by the eager server (`spec/fixtures/mcp_light`), in this process and in a child.
  - **Not clients.** A restricted server keeps its domain booted and answers in under 10 ms (ADR 0089); a call forked
    from the resident would boot it each time. An unrestricted server would need a launcher-visible command that takes
    its scope from the environment the caller sends, which widens what the launcher accepts. So a tool call is not
    forwarded to the resident, and a server that has made one holds the framework, about 48 MB.
  - **A role's server.** The `ServerEnv` query on the `Role` aggregate (`exe/hecks agents Role.server_env
    role.value=orchestrator`, adapter `RoleServerEnv`) turns the role's `RoutingRule` patterns into
    `HECKS_SERVER_TOOLS=commands`, `HECKS_SERVER_DOMAINS=lib/hecks/hecks` and the exact command names the Hecks domain
    has: `Aggregate.*` expands to every command of the aggregate, `Aggregate.verb!` to that one, and a question, a shell
    command or another bluebook's command (`Work.*` is Tickets') adds nothing. A role with no rows, or none that names
    a command, gets nothing and stays unrestricted: today only the orchestrator has rows, and it gets eleven commands.
  - **Passing it on.** `.mcp.json` is one static file, and whether Claude Code hands the environment of the `claude`
    process to the servers it starts is documented only by third-party guides ("merged with the inherited
    environment"); an unset `${VAR}` is passed on as literal text. So the session does not rely on either:
    `SessionMcp` reads the checkout's `.mcp.json`, adds the role's variables to the `hecks-mcp` entry's `env`, and
    passes it as `claude --mcp-config '<json>' --strict-mcp-config` (`SessionLine` builds the line), so the
    checkout's unrestricted entry does not start beside it. `--strict-mcp-config` also leaves out MCP servers from
    other scopes for that session. Argument construction is specified against a stand-in `claude`; no real session was
    started to see the servers come up restricted.

### Measured

| step, on the Hecks domain, macOS arm64, Ruby 3.3.7 | |
|---|---|
| resident answers `go` after the connection (the fork included) | 16 ms |
| a child's boot to the command (`boot_ms` in the usage log) | about 80 ms |
| warm `hecks tickets Work.undone` | 0.13 s |
| warm `hecks --help` | 0.11 s |
| warm `hecks agents Role.guard role.value=coder command.value=ls` (the orchestrator guard hook) | 0.13 s |
| warm `hecks RedFlag.status` (runs `git`) | 0.19 s |
| the first line after an edit under `lib/`: cold boot, then a new resident | 1.4 s on warm caches |
| a new resident's own load | about 3 s on warm caches, 8 s on cold |
| the resident's resident memory | about 300 MB |
| an idle `hecks-mcp`, framework loaded at start: resident memory, and spawn to the last of three replies | 48 MB, 237 ms |
| an idle `hecks-mcp` now: the same two figures, framework unloaded | 16 MB, 40 ms |
| the same server after its first tool call | 48 MB; 249 ms in all, so the load moves to that call and takes about 210 ms |

The two server rows were read from `ps -o rss=` in a child started as `.mcp.json` starts it
(`ruby -I lib -e ...`), fed `initialize`, `ping` and `tools/list` (then `tools/call domains`) on stdin, one run each.

The warm lines meet the 0.15 s target but `RedFlag.status`, which waits on `git`.
