# A command starts no process; a cold start is rare, counted and reported

**Status:** Accepted. Date: 2026-11-21. The owner confirmed the design in the interview `boot-fix-2026-11-21` and the
plan was reviewed by the architect (plan review run `508786b5`, verdict sound with changes, all taken). Narrows
[0201](0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md): it replaces 0201
decision 1 (one resident per checkout) and the `max_residents` ceiling, and leaves the rest of 0201 standing. It
changes nothing today: every step of the order below is code that does not exist yet, and each becomes its own work
item. Builds on [0089](0089-the-mcp-door-gets-a-commands-scope-and-stays-booted.md), whose booted restricted server
survives as one of the thin doors of decision 3.4.

## Context

ADR 0201 built a resident per checkout. Warm, it works: a launcher line costs 0.11 to 0.19 s (a fork answers in
16 ms, a child's boot to the command is about 80 ms, 0201 "Measured"). The time that remains is in the lines the
resident does not serve. 0201 "As built" records them in the usage log as `refused:busy`, `refused:env:<NAME>`,
`refused:changed`, `refused:protocol` and `refused:dropped`, and the first line after any edit under `lib/` is a cold
boot (1.4 s on warm caches) that starts a new resident, whose own load is 3 s warm and 8 s cold. In 0201's concurrency spec 42 of 42 lines were `refused:busy` and in a live sample 41 of 45 were `refused:env`. Measuring this in hours of boot, as the
earlier ADRs did, hides it: a few thousand refused lines look like a cost, and a million served ones like a saving.

## Decision

1. **The goal: a command starts no process.** A line is answered by a process that is already up. A cold start (a
   launcher that loads the framework itself) is the exception, is rare, and is reported when it happens.
2. **The measure is the count of cold starts, not hours.** A cold start is a usage-log line with `cold` true and a
   `boot_ms` (the fields 0201 already names), including every `refused:*` line that then booted on its own. The
   target is a count per day that falls toward zero and is read from the usage log by `hecks usage`. The term "boot
   hours" is retired: no record, report or budget states the goal in hours.
3. **The order, confirmed by the owner.** Each step is a work item of its own, built in this order:
   1. **One launchd-kept control process.** launchd starts and restarts it. It holds one writer per store and forks
      per write, as 0201 decision 2 decided, so each write sees a fresh runtime. It serves every checkout and
      worktree from one process only where their `lib/` and declarations are the same; a checkout whose fingerprint
      differs (0201 decision 3) is served by its own child control process, kept by launchd the same way. This
      replaces 0201 decision 1 (a resident per checkout) and the `max_residents` ceiling: the ceiling
      becomes a bound on control processes per distinct fingerprint, and the idle exit of decision 3 stays for
      those that nobody uses.
   2. **Reads come from read models.** A read is answered from a projection the control process holds, so it forks
      nothing and opens no store, runs no adapter and takes no lock. This is what makes "no fork for reads" true while
      0201 decision 2 (the resident holds no store or lock) stays true: the models are data built from events, not an
      open store. Every other line still forks.
   3. **The role guard decides from a projected rules file.** The decision stays in the bluebook; the file is only
      its projection, digest-keyed, owner-checked, mode 0600 and written atomically, as `RoleServerCache` is (0201
      "As built"). A missing, stale or unreadable file refuses and never allows, as 0216 and 0217 require of a guard
      that cannot answer.
   4. **Every door is a thin client.** The launcher, the hooks, the restricted server of 0089 and the MCP servers
      send the line to the control process and relay its answer. A door loads no framework.
   5. **Workbench commands load only what they need.** A modelling (workbench) command loads the declarations it
      names, not the whole Hecks domain. The aggregate that carries the name is chosen when the work item is cut.
   6. **A compiled domain image, last.** 0201 declined to serialize the loaded declarations because the registry holds
      mutexes and the load has effects beyond data, and invited revisiting "the part that is pure data". This takes
      that invitation, and takes it last: once reads, the guard and the doors no longer need a load, what is left to
      shorten is the control process's own start, and only then does an image of the pure-data part pay for itself.
4. **When the control process is down.** A command starts cold and says so on its own standard error and in the usage
   log (`cold`, with the reason). launchd restarts the process. More than `fallbacks_per_minute` cold starts in a
   minute raises a stall row (`Stall.file!`, as the `Hecks::FillStall` kinds do; a new kind is a work item) and
   alarms the owner. At most `max_cold_starts` run at once: a cold launcher has no process to count them, so it takes
   a claim file in the cache directory, as 0201's `<stem>.claim` does, and a launcher that cannot take one waits a
   time set in the world and then refuses by name. Both numbers are data in the Hecks world's `resident` line beside `idle_seconds`,
   `max_residents` and `ready_wait_ms`, set at first to 5 and 2.
5. **Budgets are kept honest.** A budget is a count of cold starts and a latency percentile of served lines, each read
   from the usage log, never an average that served lines dilute. A change that adds a refusal reason or a cold path
   says so in its work item, and a spec fails when a `refused:*` reason is neither listed nor counted.

## Consequences

- 0201 stands except where step 3.1 and decision 4 name it. Its decisions 2 (fork per line, nothing held open), 3
  (fingerprint, idle exit), 4 to 6 and "As built" remain the rules the control process is built under. Its
  decision 1 and its `max_residents` ceiling are what steps 3.1 and 4 change.
- 0089 is itself marked superseded by [0103](0103-doors-are-driving-adapters.md); this record cites it only for its
  booted restricted server, a thin client under step 3.4.
- Prior art, cited and not binding: the storehouse `serve-socket` daemon of 2026-05-22 (commits `31ee18c64` and
  `db0a32430`) and lazy repository hydration (`814854441`). They show a warm process answering in milliseconds and
  show how a daemon is lost when a client restarts; they decide nothing here.
- A single control process is a single point of failure for the speed, not for the data: stores are never held open
  in it (step 3.2), and a down process costs cold starts, counted and alarmed.
- Nothing in this record is built. The status says Accepted for the design; each step lands as its own work item
  with its own spec, and this record is revised by narrowing when a step changes its mind.
