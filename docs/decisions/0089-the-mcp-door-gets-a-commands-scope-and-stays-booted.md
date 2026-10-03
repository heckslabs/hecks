# The MCP door gets a commands scope and stays booted

**Status:** Proposed. Date: 2026-10-03. A spawned door can already be narrowed to reader tools (ADR 0072). A third scope serves `dispatch` for a closed list of commands, so an agent can run the Hecks chapter's own verbs through typed tools, and a restricted door keeps each named domain booted for the session.

## Context

ADR 0072 decision 2 limits a spawned door to reader tools: no `dispatch`, no `domain:` outside the named set, no `behaviors`. That leaves an agent able to read the Hecks chapter but not to run any of its verbs. The alternatives for running them are a shell wrapper that checks the first argument, or an unrestricted door whose `dispatch` can run any of the chapter's 130 commands, including the release and journal verbs.

Two measurements shaped the decision. First, in small trials agents given only an allowlisted verb surface answered in fewer turns than agents searching the repository, and the gap shrank with a stronger model. Second, a `hecks` call costs about a second of CPU before it does any work, most of it evaluating the chapters, and the door re-booted the domain on every tool call, so a resident door gained nothing for a large domain.

The chapter also repeats short command names across aggregates: `accept!`, `complete!`, `fault!` and `abandon!` each exist on ten or more run records. Those are record-keeping steps that only note what they are told. An allowlist by short name would admit all of them, and an agent could forge a passing outcome.

## Decision

1. **`HECKS_DOOR_TOOLS=commands` serves the reader tools and `dispatch`, and nothing else.** It needs `HECKS_DOOR_DOMAINS` as reader mode does, and `HECKS_DOOR_COMMANDS`, a comma-separated list of command names. The list is closed: a door refuses to start with commands but no mode, commands in reader mode, an empty list, or no domains. `behaviors` stays refused.
2. **A command is admitted by the verb it resolves to, not by the string it was asked for.** The requested name and each allowed name go through the alias map `dispatch` resolves with, and the resolved verbs are compared. `order.create_pizza` reaches `create_pizza`'s verb when that is allowed. A name that resolves to nothing admits nothing, and a name shared by several aggregates is qualified in the alias map, so an allowed short name cannot reach another aggregate's command. Dry runs and every step of a batch are admitted before anything runs.
3. **`tools/list` shows what is served.** `dispatch` carries the allowed commands as an `enum` on `command`, on each step, and in its description, so a caller sees the surface as typed tool definitions and does not need a manual.
4. **A restricted door keeps each named domain booted** until the files of its directory change (a fingerprint of each file's path, size and modification time). Both restricted modes do this; an unrestricted door boots afresh on every call, as before. A domain with in-memory persistence therefore keeps its records between calls on a restricted door.

## Consequences

- An agent can run the allowlisted verbs with typed arguments and a refusal in the domain's own words, with no shell. With the domain kept booted, a call after the first took under 10 ms in the measurement that decided this, against about 1.5 to 3 s when the door re-booted per call (Postgres-backed domain).
- The list admits commands, not argument values. A command that takes a path or a binary can still be pointed somewhere harmful: `run_spec_example file=` runs the Ruby in any spec file, `bench output=` writes where it is told, and `smoke_http` takes a URL and a payload file. Do not put such a command on the list for an agent you do not trust until per-argument constraints exist. The sample lists in this ADR's tests name only commands whose arguments name domains and paths inside the checkout.
- Identity stays self-asserted: `role:` is a claim the caller makes, as ADR 0072 says. Commands mode limits reach and identifies no one.
- A resident domain does not notice a change in the hecks code itself or in a chapter it attaches from outside its directory. The door lives for one spawner's session and is restarted with it.
- The chapter's own era check runs at the first boot, not on each call, so a database era change mid-session is not noticed until the door restarts.

## Alternatives considered

- **A shell wrapper that checks the first argument.** It works today and is what the kit uses, but it parses arguments in shell, gives agents a usage manual in the prompt instead of tool definitions, and boots hecks on every call.
- **One MCP tool per verb, with its own argument schema.** The better typed surface, projected from the same CLI table. Larger, and worth doing once the allowlist is proven; the `enum` is the first step toward it.
- **Allow by qualified name only.** Safest against the shared short names, but makes every list longer to write. The verb comparison gets the same safety with short names.
- **Cache the evaluated chapters across processes.** Rejected: the evaluated registry holds `Proc` predicates with no IR loader to rebuild them, for a gain of about half a second per call.

## Open items

- Per-argument constraints on an allowed command: values confined to paths inside the checkout, and denied argument names, as the shell wrapper's policy does.
- One tool per verb with a projected argument schema.
- Whether the door should refuse to start when an allowed name resolves to nothing in a named domain, instead of admitting nothing.
- Real access control: the roles a command declares are still unassigned and self-asserted.
