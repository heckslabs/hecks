Glass — command palette for the entire Hecks conception. 6,647 callable phrases across 80 domains.

Invoke: `/glass <query>` or `Ctrl+K` or just type a command naturally.

## Instructions

### Mode 1: Command palette (no args or partial query)

When invoked with no arguments or a partial search term, act as a command palette:

1. Search the lexicon for matching commands:

```bash
hecks_life/target/release/hecks-life lexicon hecks_conception 2>&1 | grep -i "$ARGUMENTS"
```

2. Present matches as a compact numbered list showing:
   `[n] phrase → Domain::Aggregate::Command`

3. Ask the user to pick by number or refine their search.

4. When they pick one, show the command details (params needed) and execute.

### Mode 2: Direct dispatch (exact command)

When invoked with a full command phrase:

1. Match against the lexicon:

```bash
hecks_life/target/release/hecks-life lexicon hecks_conception "$ARGUMENTS"
```

2. If match found, look up the command's parameters by finding the bluebook:

```bash
grep -r "\"CommandName\"" hecks_conception --include="*.bluebook" -l
```

Then read the command definition to find required attributes.

3. Ask for any missing parameter values.

4. Execute by persisting to heki:

```bash
hecks_life/target/release/hecks-life heki append hecks_conception/information/<Domain>.heki domain=<Domain> aggregate=<Aggregate> command=<Command> key=value ...
```

5. Show the result and offer related commands.

### Mode 3: Conversation fallback

If the lexicon returns "no match", the input is conversation — respond as Winter.

## Display format

Always show the Glass dispatch transparently:

```
⚡ Glass → Domain::Aggregate::Command (confidence%)
  params: name, description, ...
  result: { persisted record }
```

## Browsing

Full surface: `hecks_life/target/release/hecks-life lexicon hecks_conception`
By domain: pipe through `grep -i "DomainName"`
Compositions only: pipe through `grep " then "`
