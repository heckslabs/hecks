# Shell Adapter (`adapter :shell`)

A shell adapter is a named, argv-only subprocess invocation declared in
a `.hecksagon`. At runtime, `Hecks::Runtime#shell(name, **attrs)`
substitutes `{{placeholder}}` tokens, runs the command through
`Open3.capture3` (no shell), parses stdout into a declared format, and
returns a `Result` struct.

> Status: Ruby-only. The Rust `hecks-life` parser does not read
> `.hecksagon` files yet; parity is a separately-tracked follow-up.

## Declaring

```ruby
Hecks.hecksagon "Antibody" do
  adapter :memory                   # persistence — unnamed, at most one

  adapter :shell, name: :git_log do # shell — named, many allowed
    command "git"
    args ["log", "--format=%H", "{{range}}"]
    output_format :lines
    timeout 10
    working_dir "."
    env "GIT_PAGER" => ""
  end

  # Or one-liner form:
  adapter :shell, name: :git_show_files,
                  command: "git",
                  args: ["show", "--name-only", "--diff-filter=AM",
                         "--format=", "{{sha}}"],
                  output_format: :lines
end
```

Rules:

- `name:` is **required**; must be unique within the hecksagon.
- `command:` is a fixed binary name. It is rejected at parse time if
  it contains `{{` — placeholders only go in `args`.
- `args:` is an `Array<String>`. Each element may contain any number
  of `{{token}}` placeholders. There is NO shell string form — do not
  write `command "git log {{range}}"`.
- `output_format:` defaults to `:text`. Valid:
  - `:text` — stdout as a String.
  - `:lines` — non-empty chomped lines as `Array<String>`.
  - `:json` — stdout parsed as JSON.
  - `:json_lines` — each non-empty line parsed as JSON, returned as
    `Array`.
  - `:exit_code` — stdout discarded; `Result#output` is the exit
    status (`Integer`). Non-zero exit does NOT raise in this format.
- `timeout:` optional seconds (Integer or Float). If exceeded, the
  dispatcher kills the child process group and raises
  `Hecks::ShellAdapterTimeoutError`.
- `working_dir:` optional. **Must be an absolute path** when set —
  `Structure::ShellAdapter.new` raises `ArgumentError` at build time on
  relative values. The hecksagon loader resolves relative DSL input
  against the hecksagon source path before building the IR value. When
  `nil`, the dispatcher falls back to `Dir.pwd` at dispatch time (fine
  for inert tools like `echo`).
- `env:` optional Hash. The dispatcher starts from an empty env
  (`unsetenv_others: true`) and only passes what you declared here.

## Dispatching

```ruby
app = Hecks.boot(__dir__)

result = app.shell(:git_log, range: "HEAD~5..HEAD")
result.output        # => ["abc123...", "def456...", ...]
result.raw_stdout    # => "abc123...\ndef456...\n"
result.stderr        # => ""
result.exit_status   # => 0
```

## Security Model

- **No shell.** Every invocation goes through `Open3.capture3` /
  `popen3` with argv form. There is no `sh -c`, no word splitting,
  no glob expansion, no variable substitution by the shell.
- **Placeholders are per-element strings.** A payload like
  `$(rm -rf /)` becomes a literal argv element — the kernel hands
  it to the target binary as-is.
- **Baseline env is cleared.** Open3 is invoked with
  `unsetenv_others: true`, so the child process inherits only the
  env you declared on the adapter. Secrets in the parent environment
  do not leak.
- **Working directory is explicit.** There is no process cwd
  dependency — the adapter always runs in `working_dir` (or
  `Dir.pwd` when unset, which is fine for inert tools like `echo`).
- **Stdin is empty.** No piping; `stdin_data: ""`. A future
  `stdin_from:` attribute would open this surface deliberately; not
  in v1.

## Error Surface

| Error | When |
|---|---|
| `Hecks::ShellAdapterError` | Non-zero exit for any format except `:exit_code`. Carries `adapter`, `exit_status`, `stderr`. |
| `Hecks::ShellAdapterTimeoutError` | `adapter.timeout` elapsed before the child exited. Carries `adapter`, `timeout`. |
| `Hecks::ConfigurationError` | `runtime.shell(:unknown)` — no adapter with that name registered. |
| `ArgumentError` | `adapter :shell` without `name:`; duplicate adapter name within a hecksagon; validation from `Structure::ShellAdapter` (command contains `{{`, args not Array<String>, unknown output_format). |

## Example

`examples/shell_adapter/` contains a minimal end-to-end demo that
declares an `:echo_args` adapter and dispatches it via
`runtime.shell(:echo_args, msg: "hello")`.

## Related

- [hecksagon reference](hecksagon_reference.md) — full grammar
- [antibody](antibody.md) — why native `.hecksagon` adapters close
  the antibody gap for ad-hoc shell-outs
