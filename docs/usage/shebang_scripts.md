# Shebang scripts — `hecks-life run`

`.bluebook` files can be marked executable and run directly from the
shell. `hecks-life` is the ribosome; the bluebook is the script.

## Minimum form

```bluebook
#!/usr/bin/env hecks-life run
Hecks.bluebook "Greeter" do
  entrypoint "SayHello"

  aggregate "Session" do
    attribute :who, String, default: "world"

    command "SayHello" do
      attribute :who, String
    end
  end
end
```

```
$ chmod +x greet.bluebook
$ ./greet.bluebook
$ ./greet.bluebook who=Miette
```

The parser strips the `#!` line. `entrypoint "CommandName"` is the
command `hecks-life run` dispatches. Extra argv entries of the form
`key=value` bind as attributes.

## Companion hecksagon

If `greet.bluebook` has a sibling `greet.hecksagon`, it is loaded
automatically and its adapters drive I/O. Without a companion the
script is pure-memory.

```bluebook
# greet.hecksagon
Hecks.hecksagon "Greeter" do
  adapter :memory
  adapter :stdout
end
```

Supported adapters today:

| Adapter    | What it does                                 |
|------------|-----------------------------------------------|
| `:memory`  | Ephemeral repositories (default)             |
| `:heki`    | Persist to `.heki` stores (opt-in)           |
| `:stdout`  | `println!`-style output, `{{placeholder}}`   |
| `:stderr`  | Same, but stderr                             |
| `:stdin`   | Blocking readline                            |
| `:env`     | Bind selected env vars (`keys: [...]`)        |
| `:fs`      | Read files (`root:` option)                  |
| `:shell`   | Named shell-out with fixed binary + args    |

## Exit codes

| Code | Meaning                          |
|------|----------------------------------|
| 0    | clean run                        |
| 1    | parse failure (or file missing)  |
| 2    | guard failure (no `entrypoint`)  |
| 3    | adapter failure (runtime error)  |
| 4    | entrypoint command not found     |

## Interactive REPL

When the companion hecksagon declares both `:stdin` and `:stdout` and
the bluebook exposes `ReadLine` + `RespondWith` commands,
`hecks-life run` runs an interactive loop. The
[terminal capability](../../hecks_conception/capabilities/terminal/)
is the canonical example.

```
$ hecks-life run capabilities/terminal/terminal.bluebook
❄ Miette · waking · — · 0 musings · 0 turns
type to talk. ctrl-d to leave.

  ❄
```

## Legacy REPL

The old `hecks-life run <file>` meaning (interactive REPL, no script
mode) lives on as `hecks-life repl <file>`. Everything else in the CLI
surface — `parse`, `validate`, `inspect`, `dump`, `heki`, `behaviors`,
`check-*`, `serve` — is unchanged.
