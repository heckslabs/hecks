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
5. **A restricted door checks arguments by name, for `dispatch` and for `query`.** A list of commands admits commands, not values, so a command that takes a path or a binary could still be pointed somewhere harmful. Three classes of argument name are checked on the way in, descending into nested objects and every step of a batch:
   - **Denied names** are refused whatever the command: those that name a host or a URL, a binary to run, a place to write, a port, a store to switch to, or that flip a command from a preview to a change of state (`McpDoorScope::DENIED_ARGUMENTS`).
   - **Path names** pass only when each value resolves inside `Storehouse::BOOT_ROOT` with symlinks followed (a link above a file that does not exist yet is followed too) and holds no colon, so `host:repo` and `https://host/x` cannot pass as relative paths (`PATH_ARGUMENTS`).
   - **Ref names** pass only as plain git refs: no leading dash, no `..` (`REF_ARGUMENTS`).

   Other names pass unchecked. A spec lists every argument name of every public command of the Hecks chapter and fails when one is in none of the three classes or a short list of names known to be plain data, so whoever adds an argument that reaches outside the checkout has to say so.
6. **The door says how to call it, so a caller needs no manual.** Trials of a small model using the door with no usage text showed where it lost turns, and each is answered where the model reads it:
   - **A door that serves one domain makes `domain:` optional** (not required in the schema, and filled in when left out). A caller that passed another domain, as one did for a model check on a different project, is still refused.
   - **`dispatch` lists each allowed command in its description** with the role it declares, what it does, and its argument names, a `*` marking a required one, read from the booted domain, and says to pass that role as `role` and that `run` is a key the caller chooses.
   - **`dispatch` answers the record as it stands once the reactions have run**, as the launcher's `--wait` does, instead of the record as the command left it. A run record that a reaction completes used to read as `requested`, so a caller had to know to read it back with `state`. This applies to every door, restricted or not.

## Consequences

- An agent can run the allowlisted verbs with typed arguments and a refusal in the domain's own words, with no shell. With the domain kept booted, a call after the first took under 10 ms in the measurement that decided this, against about 1.5 to 3 s when the door re-booted per call (Postgres-backed domain).
- Argument checking is by name, which is its limit. For the Hecks chapter the classification is complete and held by a spec; a domain whose own commands take an argument that reaches outside its files has to name it in the constants above, since an unclassified name passes. A path inside the root is still a path the command acts on: `run_spec_example file=` runs the Ruby in any spec file under the root, so keep the root to the checkout and give an agent no way to write a file there.
- A command whose point is to change state or reach a host (`smoke_http`, `bench` with an output, the publishing commands) is blocked by its argument names where they are denied, but is better left off the list.
- Identity stays self-asserted: `role:` is a claim the caller makes, as ADR 0072 says. Commands mode limits reach and identifies no one.
- A resident domain does not notice a change in the hecks code itself or in a chapter it attaches from outside its directory. The door lives for one spawner's session and is restarted with it.
- The chapter's own era check runs at the first boot, not on each call, so a database era change mid-session is not noticed until the door restarts.

## Alternatives considered

- **A shell wrapper that checks the first argument.** It works today and is what the kit uses, but it parses arguments in shell, gives agents a usage manual in the prompt instead of tool definitions, and boots hecks on every call.
- **One MCP tool per verb, with its own argument schema.** The better typed surface, projected from the same CLI table. Larger, and worth doing once the allowlist is proven; the `enum` is the first step toward it.
- **Allow by qualified name only.** Safest against the shared short names, but makes every list longer to write. The verb comparison gets the same safety with short names.
- **Cache the evaluated chapters across processes.** Rejected: the evaluated registry holds `Proc` predicates with no IR loader to rebuild them, for a gain of about half a second per call.

## Open items

- Constraints declared on the bluebook's own types, not by argument name, so the classification cannot drift from the types: the projection reduces each argument to a primitive type, so this needs the declared type name carried through to it.
- One tool per verb with a projected argument schema.
- Whether the door should refuse to start when an allowed name resolves to nothing in a named domain, instead of admitting nothing.
- Real access control: the roles a command declares are still unassigned and self-asserted.
