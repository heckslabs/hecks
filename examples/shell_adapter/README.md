# examples/shell_adapter

A minimal demo of the `adapter :shell` hecksagon kind.

## Files

- `hecks/shell_demo.bluebook` — minimal domain
- `hecks/shell_demo.hecksagon` — declares two shell adapters:
  - `:echo_args` — `echo {{msg}}` (text output)
  - `:list_files` — `ls {{dir}}` (lines output, 5s timeout)
- `shell_demo.rb` — boots the domain and calls both adapters

## Run

```sh
ruby -Ilib examples/shell_adapter/shell_demo.rb
```

Expected output ends with:

```
--- :echo_args ---
output:      "hello\n"
exit_status: 0

--- :list_files (current dir) ---
first 3 entries: ["hecks", "shell_demo.rb"]
total entries:   2
```

See [docs/usage/shell_adapter.md](../../docs/usage/shell_adapter.md)
for the full reference.
