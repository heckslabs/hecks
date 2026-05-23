Glass — command palette for the entire Hecks conception. 929 callable phrases, every one routed through the bus.

Invoke: `/glass <query>` or `Ctrl+K` or just type a command naturally.

Everything goes through `hecks-life storehouse` (the bus door). Never `heki append`, never raw file edits to information/*.heki — those bypass the bus and are a mistake.

## Instructions

### Mode 1: Command palette (no args or partial query)

When invoked with no arguments or a partial search term, act as a command palette:

1. Browse the lexicon for matching phrases (substring filter on the phrase):

```bash
hecks-life storehouse list "$ARGUMENTS"
```

   Output is tab-separated `Phrase<TAB>bluebook_path`, e.g.
   `Speaker.TalkWith\t/.../console.bluebook`.

2. Present matches as a compact numbered list:
   `[n] Aggregate.Command  (← bluebook basename)`

3. Ask the user to pick by number or refine their search.

4. When they pick one, resolve it (Mode 2 step 1) to show params, then execute.

### Mode 2: Direct dispatch (exact phrase)

When invoked with a full `Aggregate.Command` phrase:

1. Resolve the phrase to its target (exact match — substrings miss):

```bash
hecks-life storehouse lookup "$ARGUMENTS"
```

   Returns JSON: `{aggregate, command, bluebook_path, domain_phrase, phrase}`.
   If it prints `phrase '...' not found`, fall through to Mode 3.

2. Find required attributes by reading the command definition in the
   `bluebook_path` the lookup returned (through the bus):

```bash
hecks-life storehouse route Tools::FileTool.Read file_path=<bluebook_path>
```

   (or just open it) and read the command's `attribute` lines.

3. Ask for any missing parameter values.

4. Execute by routing through the bus — this IS the dispatch:

```bash
hecks-life storehouse route "$ARGUMENTS" key=value key2=value2 ...
```

5. Show the result envelope and offer related commands.

### Mode 3: Conversation fallback

If `lookup` returns "not found", the input is conversation — respond as Miette.

## Display format

Always show the Glass dispatch transparently:

```
⚡ Glass → Aggregate.Command
  params: name, description, ...
  → hecks-life storehouse route <phrase> key=value
  result: { dispatch envelope }
```

## Browsing

Full surface (929 phrases): `hecks-life storehouse list`
By substring:               `hecks-life storehouse list <filter>`
Resolve one phrase to JSON:  `hecks-life storehouse lookup <Aggregate.Command>`
Project a heki attribute:    `hecks-life storehouse read <Aggregate.attribute>`
Rebuild the lexicon:         `hecks-life storehouse compile`
