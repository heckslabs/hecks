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
`wire.rb`, `paths.rb`, `crowd.rb` (the cap), `peer.rb` (who is on the other end) and `env_trace.rb`. Decisions 1 to 5
stand. Where the build differs from the text above or adds to it:

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
  `BUNDLE_GEMFILE`, `RUBYOPT`, `RUBYLIB`, `GEM_HOME`, `GEM_PATH`, `HECKS_NO_USAGE_CACHE` or `HECKS_ENGINE` differs
  from the resident's own is answered by the launcher itself, because the code read those when it loaded (a caller
  with other gem paths must not be served by this resident's gems). `HECKS_ENVIRONMENT` is not one of them: each
  environment is its own cached load (`Loading::PER_LINE`). The loading code does read it, so `EnvTrace` notes it,
  and until it was taken out of the match every line made with `HECKS_ENVIRONMENT=memory` (the gate stages, the
  Memory overlay, the launcher's own `MEMORY_COMMANDS`) was refused as stale and booted cold, and a resident
  spawned from a shell that exported it served only that flavour. `PATH`, `TZ` and `LANG` are not matched: they
  differ between a hook, a session and a terminal, so matching them would send most lines away from the resident,
  and a caller that runs another Ruby is not told apart (the child is forked from the resident's Ruby; the launcher
  that sent it ran under the caller's). The list is not only those nine. While the resident loads the
  code, `EnvTrace` notes every `HECKS_*`, `CARGO_*` and `PG*` variable read through `ENV` (`HECKS_STOREHOUSE_ROOT`,
  `HECKS_QUIESCE_STATE`, `HECKS_MINT_STATE` and the rest), and a line whose value of one of them differs, or that
  sets one the resident loaded without, is answered by the launcher itself. A variable read only when a line runs
  (`HECKS_CALLER`) is never noted, so it does not send a session's lines away from the resident.
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
    That the goldens equal the old server's replies was not re-checked from an independent run of the old code. A
    load that fails (a `LoadError` or `SyntaxError` is a `ScriptError`) is answered `-32603 framework failed to load`
    on that call and every later one, without trying again (`McpLazyLoad`); a batch is answered `-32600`.
  - **Not clients.** A restricted server keeps its domain booted and answers in under 10 ms (ADR 0089); a call forked
    from the resident would boot it each time. An unrestricted server would need a launcher-visible command that takes
    its scope from the environment the caller sends, which widens what the launcher accepts. So a tool call is not
    forwarded to the resident, and a server that has made one holds the framework, about 48 MB.
  - **A role's server.** The `ServerEnv` query on the `Role` aggregate (`exe/hecks agents Role.server_env
    role.value=orchestrator`, adapter `RoleServerEnv`) turns the role's `RoutingRule` patterns into
    `HECKS_SERVER_TOOLS=commands`, `HECKS_SERVER_DOMAINS=lib/hecks/hecks` and the exact command names the Hecks domain
    has: `Aggregate.*` expands to every command of the aggregate, `Aggregate.verb!` to that one, and a question, a shell
    command or another bluebook's command (`Work.*` is Tickets') adds nothing. Only a role with no rows at all stays
    unrestricted: today only the orchestrator has rows, and it gets eleven commands. A role that has rows and none of
    them names a command gets no variables, and that is not permission (see "Fails closed" below).
  - **Flags do not survive a resume (tested live, 2026-11-09).** A session started with `claude -p --mcp-config <file>
    --strict-mcp-config` listed only that file's server in its `init` message; the same session resumed with
    `--resume <id>` and no flags listed the default servers (`plugin:linear:linear`), not the file's. And a resume
    given flags starts a copy (the comment in `ClaudeResumption`). So a restriction passed as flags at start is gone
    when an answer wakes the session, and `--strict-mcp-config` had also dropped every plugin and connector server for
    the session. The session start therefore passes no MCP flag (`SessionLine`); `SessionMcp` and `SessionConfigFile`
    are removed.
  - **The server learns its role from the environment (live, same day).** A server Claude Code starts receives the
    session's environment: `CLAUDE_CODE_AGENT` (the agent name, `orchestrator` under `--agent orchestrator`),
    `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PROJECT_DIR`. A probe server under `claude -p --agent orchestrator` listed them.
    Every start, including a resumed session's, runs the same server with the same variables, so the server narrows
    itself (`Driving::Mcp::Roles`):
    - an explicit `HECKS_SERVER_*` setting wins and is read exactly as before, refusals included;
    - otherwise `CLAUDE_CODE_AGENT` names the role. A role with no routing rows, no agent, or a checkout with no Agents
      bluebook stays unrestricted. A role whose rows name commands becomes a `commands` server for exactly those
      (`HECKS_SERVER_DOMAINS` is the checkout's `lib/hecks/hecks`). A role that has rows and none names a command
      serves no tool, and every call is refused `no commands for role <name>` (`McpScope#closed_role`).
  - **Startup stays light (`RoleServerCache`).** What a role's rows name is known only to the framework, so it is
    worked out once per checkout state and written to `<cache>/role-servers/<digest>.json` (0600, atomic rename, the
    newest 16 kept). The digest covers the checkout's bluebooks under `lib/hecks/hecks` and `lib/hecks/agents` and its
    `version.rb`, so an edit to a routing row or a command misses. The server reads the file with the standard
    library only and checks that this user owns it and nobody else can write it. On a hit nothing loads at startup:
    an idle server holds 16 to 17 MB with or without a role (measured: no agent 16.0 to 16.7 MB; a cached role with no
    rows 16.4 to 16.6; a closed role 16.0 to 17.0; a role with commands, after `initialize` and `ping`, 16.3 to 17.6).
    On a miss the framework loads at the first call that needs the scope, `RoutingGuard#server_table` works out every
    role's commands, and the file is written for the next server. `Role.server_env` refreshes the same file. A
    checkout whose Agents bluebook cannot answer serves no tool (a failed table is not written), because that the role
    has no rows cannot be shown. The first server after any landing under those bluebooks pays the load once.
  - **Fails closed.** A role that has routing rows never gets an unrestricted `hecks-mcp`: an empty expansion and an
    unreadable table both serve no tool.
  - **The checkout is the one the server serves.** The rows and command names are read from `Storehouse::BOOT_ROOT`,
    the checkout whose `lib` the server runs, which is the session's checkout when `.mcp.json` starts it with
    `ruby -I lib`. The list is fixed when the server starts, so a row removed afterwards does not revoke a command for
    a server already running; a session woken by an answer starts a new server and reads the current rows.
  - **Accepted: the server reads more than the Bash guard allows.** The `commands` mode narrows `dispatch` to the
    role's commands but still serves the reader tools (`query`, `state`, `events`, `describe`, `catalog`, `history`)
    and `Codebase.ReadSource` through `READ_PATH_QUESTIONS`, against everything under the boot root. A role's Bash is
    held to its rows by the guard hook, which matches `Bash` only, so a restricted server reads more than the role's
    Bash may.
  - **The orchestrator cannot reach its server (tested live, 2026-11-09).** `.claude/agents/orchestrator.md` says
    `tools: Bash`. A real `claude -p --agent orchestrator` run with this checkout's `.mcp.json` reported both servers
    `connected`, and its `init` event listed `["Bash"]` as the session's tools: no `mcp__` tool at all. The allowlist
    hides them, so the orchestrator's restricted server is unreachable today and its saving is the idle servers it no
    longer holds. The same run with an inline agent named `orchestrator` and no allowlist (`--agents`) listed ten
    `mcp__hecks-mcp__*` tools (`catalog describe dispatch domains events follow history query state validate`) of the
    eleven the unrestricted server defines (the one missing is `behaviors`): the role was narrowed from
    `CLAUDE_CODE_AGENT` alone, with no flag and no `HECKS_SERVER_*` setting. Naming `mcp__hecks-mcp__*` in the
    orchestrator's `tools` would make the restriction matter; that is the owner's decision.
- **A resume names the role.** Measured with `claude -p` on haiku (2026-11-09), from the hecks checkout with the
  project's `hecks-mcp` and an inline agent named `orchestrator`: a fresh start exposed 10 `mcp__hecks-mcp__*`
  tools; a plain `--resume` of that session left the server's `CLAUDE_CODE_AGENT` at `claude` and it exposed all
  11 (the restriction lost); `--resume --agent orchestrator` kept the same session id (no copy) and gave 10 again
  (with a probe server, `CLAUDE_CODE_AGENT=orchestrator`). So `ClaudeResumption` passes `--agent <role>` for a run
  that has a role (`AgentRun`'s `agent`, the same value the start passed), ahead of `--bg --resume`, and no other
  flag; a run with no role resumes as before. Not run: a resume of a real dispatched session.
- **A line runs only after the words.** The request states its own length and the resident reads that many bytes
  and no more. It then answers `fds` when it can serve the line (or `stale`, which sends the launcher on to boot),
  and only then does the caller send its three streams: on Linux a read of the request could take the first
  stream's bytes with it and drop that descriptor, which the order rules out without leaning on the kernel. The
  resident answers `ready` once it has the three streams; the caller answers `go`; the resident forks only then,
  and ends with the status. The exchange costs one round trip more than before. From the moment the resident
  takes a caller up to the fork the whole exchange has one deadline of 5 seconds, so a caller that stalls in any
  step holds the single accept loop for 5 seconds at most, not for each step's wait in turn.
  A caller that gave up on a slow resident has closed its socket (the client closes it on every path, before it
  boots on its own), so a request that sat in the queue meets a closed connection and is dropped. Before this a
  busy resident would later accept the queued request and run the line a second time, beside the launcher's own
  cold boot. The request is written within a deadline, so a resident that is stopped but still accepting makes
  the launcher fall back instead of waiting for ever. A real resident stopped with `SIGSTOP`, called, and resumed
  ran the line once.
- **Who may talk to it.** The client sends nothing until the resident directory and its parent are this user's and
  closed to everyone else, the socket is a socket of this user's that others cannot write, and the kernel's record
  of the peer (`LOCAL_PEERCRED` on macOS, `SO_PEERCRED` on Linux) names this user. The resident checks the same of
  each caller, binds its socket under a restrictive umask, and loads only the launcher it was started from: a
  request naming another script is refused. Where the system does not name the peer, the directory ownership is all
  there is. `HECKS_CACHE_DIR` set to a directory others can write to means no resident is used.
- **No resident where the cache directory is new each time.** When the cache root falls back to a per-process
  temporary directory (`Hecks::CacheDir.stable?` is false) and `HECKS_CACHE_DIR` is not set, no launcher asks for or
  starts a resident: each would find an empty directory and start one that lives for the idle time.
- **The cap is met before anything loads.** A resident counts the others and ends before it loads when the cap is
  met, and a launcher does not start one then. The cap a resident read from the world is kept in the resident
  directory (`cap`), so the count before the load uses it; with none written it is the default of 8.
- **Limits on a request.** A field may be 1 MiB, a request 8 MiB and 20,000 fields, and the whole exchange up to
  the fork must finish within the one 5-second deadline; anything else is dropped, with the streams it carried
  closed. Finished lines are dropped from the monitor list on each turn.
- **What retires it.** The fingerprint also lists the launcher, `.ruby-version`, the `*.world`, `*.hecksagon` and
  `*.bluebook` files at the checkout's root and the hidden files under `lib/`. A domain directory outside `lib/`
  that a child asked the resident to load joins what the resident was built from when it is loaded, so learning a
  domain does not retire the resident. A file replaced by one of the same size whose modification time is put
  back (`rsync -t`, an unpacked archive) is not seen; that gap is accepted.
- **Looking is cheaper than listing.** Before, every line walked `lib/` (2,363 files and 366 directories on this
  checkout), stat'ed every entry and compared the whole listing. Now an answer is reused for 1 second, so a change
  is seen by the first line more than a second after it. A look between full listings re-stats the files already
  listed and the directories that hold them with no walk: an edited or removed file shows in its own stat and an
  added or renamed one in its directory's modification time. The tree is listed again every 30 seconds and
  whenever a look finds something different. A file added to a directory that was not listed, inside the second its
  parent changed, waits for the next full listing. By the count of what is touched (not timed: a timing script
  was refused in the session that made the change) a look is the same 2,729 stats but no directory reads and none
  of the strings and the hash a listing builds, and it runs once a second at most, not once a line.
- **A child that is stopped is stopped with what it started.** When the caller's end of the socket closes before the
  line is done, the resident signals the child's whole process group, which the child leads (it calls `setpgid`
  right after the fork and the resident does too, so the group stands whichever runs first): `INT`, then `TERM`
  after 5 seconds and `KILL` 10 seconds later for a child that does not leave. A build or gate the line started is
  stopped with it.
- **Servers that run for days stay with the launcher.** `PipelineBoard.serve!` (which re-execs itself), the `Server`
  commands `present!`, `compose!` and `preview!`, and `serve_query_ir_mcp!` are never sent to a resident: each would
  be a forked child with a caller waiting above it for as long as the server lives. Like `console` and `mcp`, they
  are recognized by the word however it is spelled.
- **It keeps no terminal.** The resident starts a new session (`setsid`) when it begins, so a child that opens
  `/dev/tty` finds no terminal of the first launcher that started it.

### Under concurrent callers

The usage log of 2026-11-09 (hour 09Z, six sessions running specs at once) showed 4 lines served of 108
recorded, 59 `refused:busy`, 29 `refused:dropped`, 12 `started` and 3 `refused:changed`. A `refused:busy` line
took a median 4.4 s against 1.9 s for a launcher that never asked a resident: it waited the whole 3-second
handshake before it booted. The causes, and what was changed:

- **The launcher waited too long for a busy resident.** An idle resident says `fds` in milliseconds, so the first
  word is now waited for at most the Hecks world's `ready_wait_ms` (default 400); the resident writes the setting
  beside its socket for the launchers, which run before anything loads. Once the resident has said `fds` it has
  committed, and the later steps keep the 3-second limit.
- **The accept loop was single-threaded.** The accept thread now queues each caller for a pool of `workers` (8)
  worker threads, each taking one caller through the handshake. A caller that sat in the queue for more than a
  second has booted on its own (it waits 0.4 s), so the worker drops it unread.
- **Only the fork takes turns.** Forks, and the loading of what children found missing (`learn`), run under one
  lock so a fork never copies the resident part way through a load. A child closes every other caller's socket
  and stream it inherited: they would otherwise be held open, and a caller piping a line's output would wait for
  another caller's line to end.
- **The socket appears only when the resident is ready.** The verdict flush and `Process.warmup` (`settle`) ran
  after the socket was bound, so the first callers waited through them; they now run before `bind`, and callers
  before that boot at once.
- **The change check left the request path.** An upkeep thread, twice a second, reaps finished lines, loads what
  children found missing, looks for a change in the code or the declarations and retires the resident when it
  finds one; a line reads the answer instead of looking. A resident without an upkeep thread (a spec's) looks for
  itself.
- **One launcher starts the replacement.** When the resident retires, a burst of launchers finds none. The first
  to create `<stem>.claim` starts the replacement and the rest boot on their own at once (`none`); the resident
  that starts removes the claim when it holds the lock, and a claim older than ten seconds is taken over.
- **`dropped` names its cause.** `dropped:deadline` is the resident giving up on a caller that took longer than
  the five seconds of the whole exchange (it says so before it hangs up); `dropped:closed` is a hang-up with
  nothing said.

Measured with `spec/resident_concurrency_spec.rb`, which starts a real resident on a throwaway cache and fires
`hecks tickets Work.undone` from threads, on the unchanged resident (main at 8bb8d295f) and on this change:

| scenario | before | after |
|---|---|---|
| 24 lines together, machine quiet: served; median, slowest | 24; 0.94 s, 0.96 s | 24; 0.33 to 0.88 s, 0.37 to 0.96 s over four runs |
| 12 lines while the resident is stopped (`SIGSTOP`): outcome; median | 12 `refused:busy`; 5.74 s | 12 `refused:busy`; 3.0 s |
| 12 lines after the code changed, resident retired: outcomes | not measured | 11 `none`, 1 `started`; median 2.8 s |
| 48 lines with one busy process per core: served; median, slowest | 48; 5.3 to 10.2 s, 8.7 to 12.4 s | 48; 7.4 to 8.6 s, 9.9 to 13.9 s |

The loaded row is dominated by the work competing for the cores, and the unchanged code alone ranged from 5.3 to
10.2 s between two runs, so it shows no difference either way. The stopped row is the 3.0 s the launcher waited
before, now 0.4 s, plus a cold boot. The quiet row varies with whatever else the machine is doing.

### Protocol skew

A resident and a launcher can disagree about the words they say: the handshake changed from a plain
request to a length-prefixed one with an `fds` acknowledgement, and a resident that was already standing
could not parse the new launcher's request. It sat idle with its socket open, never answered, and every
launcher line recorded `refused:busy` and paid the wait plus a cold boot (42 of 42 lines measured, median
1.8 s) until the process was killed by hand. A fresh resident then served 65 of 67 lines. The old one could
not retire itself: the check that retires a resident whose code changed runs after a request is parsed,
every failing connection counted as use so its idle timer kept resetting, and its lock kept a replacement
from starting.

- **The protocol is in the file names.** `Wire::PROTOCOL` is part of the stem of the socket, lock, pid and
  version files (`<8 hex of the checkout>-p<protocol>.sock`). A launcher of another protocol looks at other
  files, so it never connects to the old resident and never contends for its lock; it starts a resident of its
  own. Raise `PROTOCOL` whenever the words, their order or the request's shape change.
- **The launcher says why.** When it finds no resident of its own protocol but a resident of another holds a
  lock of the checkout's, it notes `refused:protocol` in the usage log and does not connect.
- **An unused resident goes idle.** Only a line that runs, and the end of one, counts as use. A caller that
  fails the handshake, for any reason, leaves the resident as idle as it was, so a resident no caller can use
  exits within `idle_seconds` however many callers keep trying.
- **A stuck resident is stopped.** A launcher that finds the resident too busy to answer twice in a row, within
  a minute (`Stuck`, a `.busy` note beside the socket), sends it `TERM`, and only if the process id file names a
  process of this user's whose command line holds `resident/server.rb` and the checkout. The next line starts a
  new resident. The resident also writes a `.version` file with its protocol and process id.
- **Not covered.** A resident of the same protocol whose code is stale still retires through the fingerprint
  check as before; a pre-existing resident of the old, unnamed stem stands until its idle time passes, and is
  counted toward `max_residents` while it does.

### A resident's environment

A resident compares each line's variables with the ones it loaded under, and until now those were whatever
its spawner's environment happened to be. A resident started from a spec harness, a hook, a `bundle exec` or
a session with `HECKS_*` set refused every ordinary caller: 41 of 45 lines measured were `refused:env` at
1.36 s (a cold boot) until the process was stopped by hand, after which a resident started from a plain
shell served 41 of 45 at a median of 0.20 s. Many different processes call `exe/hecks`, so any of them
could have been the one that started it.

- **Every resident starts plain.** `SpawnEnv.build` keeps `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`,
  `LC_*`, `TMPDIR`, `TERM`, `XDG_CACHE_HOME` and `HECKS_CACHE_DIR` (with `HECKS_RESIDENT_PROTOCOL`, which a
  spec uses to stand in for a resident of another protocol: both name where the resident's own files live),
  and the launcher spawns the resident with
  `unsetenv_others`. Every other `HECKS_*`, `CARGO_*` and `PG*`, `BUNDLE_*`, `GEM_*`, `RUBYOPT`, `RUBYLIB` and
  `CLAUDE_*` variable is dropped, and the resident sets Bundler up for itself as the launcher does. A caller
  whose environment matters (`HECKS_ENGINE`, `HECKS_STOREHOUSE_ROOT`) is still refused, and boots cold.
  Under `bundle exec` a caller carries `BUNDLE_GEMFILE` and `RUBYOPT`, so it is refused too; the specs'
  launchers scrub those so they look like a terminal.
- **The rbenv hook directory on `RUBYLIB` is not a difference.** The first live check after the plain start
  showed 42 of 46 lines `refused:env:RUBYLIB`: the rbenv shim puts `…/rbenv.d/exec/gem-rehash:` on `RUBYLIB`
  for every Ruby it starts, so every launcher carries it and a resident started without the shim did not. The
  specs missed it because their launchers run the real Ruby directly. `EnvValue` drops entries under
  `/rbenv.d/` from `RUBYLIB` before the comparison and before the baseline is written; a path of the caller's
  own still counts. The usage log's `refused:env:<NAME>` is what found it.
- **The refusal names the variable.** The reply is `stale:env:<NAME>`, the first three differing variables
  joined with `+` (never their values, at most 48 bytes so the reply fits one wire line), and the usage log
  records `refused:env:<NAME>`. The resident section of `hecks usage` lists them.
- **A resident not born plain is replaced.** The resident writes the names of the variables it was born with
  beyond the cache ones to a `.baseline` file (empty for a plain one). A launcher that is refused on the
  environment three times within a minute (`Atypical`, a `.envs` note beside the socket) and finds the
  resident was not plain, or never said (an older resident), stops it with the same checks as a stuck one
  (`Stuck`: this user's process, whose command line holds `resident/server.rb` and the checkout). A plain
  resident that refuses an odd caller is never stopped however often it does.
- **Not covered.** A caller on a different Ruby, or with `PATH`, `TZ` or `LANG` differing, is still served by
  the resident's Ruby and locale; those differ between a hook, a session and a terminal, and matching them
  would send most lines away from the resident.

### The warm path

Where a served line's 0.19 s went, by phase (`HECKS_TRACE_TIMING=1` prints each mark on the wall
clock, to standard error, from the launcher and from the child; medians of 20 calls of
`hecks tickets Work.undone`, before any of the changes below):

| phase | ms |
|---|---|
| the shell to the launcher's first line (the rbenv shim, Ruby, rubygems) | 64 |
| the launcher to its connection (the client's `require`s and path checks) | 11 |
| the handshake: request, `fds`, `ready`, `go` | under 1 |
| the fork to the child holding the caller's streams | 5 |
| the launcher script loaded, to the usage answer | 5 |
| `Hecks.boot_described`: the boot gates, of which `verify!` is 46 | 52 |
| `CliRunner.call`: the query itself | 28 |
| the child's end, to the caller's | 18, of which 9 walked the heap for `Tempfile`s |

What changed, each with the line's behaviour kept:

- **The declaration checks run once, in the resident.** `Registry#verify_declarations!` (the eight
  checks that read only declarations, worlds and adapter classes) runs when the resident loads a
  domain, and a registry that passed skips it. `Declarations#verified` is cleared by `store`,
  `remove`, `append` and `record_source`, so a declaration added later runs them again. A domain that
  fails them is held as it is and each child refuses it in a cold launcher's words. About 14 ms.
- **A read-only boot opens only what the line reads.** A question the Hecks world lists under
  `reads_tap` (now `Work.undone`, `AgentRun.running`, `AgentRun.tidyable`, `PlanReview.reviews`,
  `Role.guard` and `Role.server_env`, beside the two it had) boots with `read_only`, which now also
  leaves the repository of every other bound aggregate unopened until a line asks it something, and
  skips the saga-checkpoint check, since it resumes no saga. About 19 ms for a `Work` query, which
  no longer opens the stores of `AgentRun`, `Pipeline` and `Agents`; with the first change,
  `boot_described` went from 52 ms to 18. A store that cannot be opened
  surfaces when the line first reads it, not at boot, and only for these listed questions; a boot
  that acts checks every store as before.
- **A child's temporary files are recorded, not found.** The child closes the `Tempfile`s it made
  instead of walking the inherited heap for them. 9 ms.
- **The client loads less.** `fileutils`, `tmpdir`, `etc`, `crowd`, `claim` and `spawn_env` load only
  when a resident is to be started (`Resident::Starting`) or a directory is to be made, and a file the
  served path clears is deleted with `File.delete`. `Hecks::CacheDir` makes its directory with
  `Dir.mkdir` and asks the system for the temp directory only when no cache directory serves. About
  6 ms (the launcher's start to the child holding the streams went from 16 ms to 11).
  `lib/hecks.rb` requires the three standard-library files itself, so the framework's own files
  that used them without a `require` of their own are unaffected.

The shim is outside the repository: `ruby` on this machine is an rbenv shim, which costs about 30 ms
before the interpreter starts, and rubygems another 30 ms that a client which never loads a gem does
not need (`ruby --disable-gems exe/hecks` served the line in 0.07 s; the launcher's cold path would
need a `require "rubygems"` before `bundler/setup` to allow it, which is not done).

After: `hecks tickets Work.undone` 0.19 s to 0.13 s, `hecks agents Role.guard` 0.18 s to 0.11 s and
`hecks --help` 0.10 s to 0.08 s (medians of 30 calls, main's resident and this branch's in turn, the
same minute). The output and status of eight polled lines were compared byte for byte between the
two and are identical.

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

### The launcher starts without rubygems

About 60 ms of a served line is spent before the launcher's first line, and a third of it is Ruby loading
rubygems. The thin client needs only the standard library, so the executable launcher's shebang is
`#!/usr/bin/env -S ruby --disable-gems` (`LaunchPrelude::EXECUTABLE_SHEBANG`), and the launcher runs
`require "rubygems" unless defined?(Gem)` right after the resident probe, so the cold path has the gems and
`bundler/setup` as before. Every other launcher (`PLAIN_SHEBANG`) has no probe and keeps `#!/usr/bin/env ruby`.

Measured on macOS arm64, Ruby 3.3.7 behind the rbenv shim, 80 alternating runs each, in milliseconds:

| | p50 | p90 |
|---|---|---|
| `ruby -e 1` | 61.6 | 62.9 |
| `ruby --disable-gems -e 1` | 41.3 | 42.3 |
| the real interpreter, `-e 1`, then with `--disable-gems` | 26.2, then 5.7 | 27.1, then 6.2 |
| `/usr/bin/env -S ruby --disable-gems -e 1` against the same without `env` | 41.5 against 40.3 | 42.2 against 40.9 |
| `exe/hecks --help`, old shebang (main) against new shebang (worktree), both served | 84.7 to 85.5 against 64.0 to 64.9 | 88.9 to 128.6 against 66.4 to 67.7 |

So rubygems costs about 20 ms, `env -S` about 1 ms, and the shim about 35 ms that stay (the real interpreter path is
machine-specific and is not hardcoded). Inside the launcher the client reaches the end 22.6 ms after its first line with
`Gem` still absent, and the resident's forked child, which has the gems, takes about 5 ms.

What was checked about the other ways to start it:

- `ruby exe/hecks`: Ruby reads the options on a script's own shebang line, so `--disable-gems` applies here too and the
  cold path loads rubygems itself. A comparison of `ruby exe/hecks` with `ruby --disable-gems exe/hecks` therefore shows
  nothing (63.6 ms each); the baseline has to be a launcher with the old shebang.
- `bundle exec exe/hecks`: `RUBYOPT=-rbundler/setup` loads rubygems before the script, and a script with the new
  shebang still reports `Gem` loaded under it.
- `env -S` is in macOS's `/usr/bin/env` and in GNU coreutils 8.30 and later (Ubuntu 20.04 and later, Debian 10 and
  later). An older `env` would fail to start the launcher, which is the one risk the change takes; a machine like that
  runs `ruby exe/hecks` or restores the plain shebang.
- A gem install is expected to be unaffected, since RubyGems writes its own wrapper script for an executable; that was
  not run here.
- `spec/launcher_shebang_spec.rb` starts the launcher cold through its shebang, under `bundle exec` and as a script
  argument to `ruby`, and pins both shebangs and the position of the `require "rubygems"` after the probe.
