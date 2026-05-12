# Claude Tool Adapter (`adapter :claude_tool`)

A `:claude_tool` adapter binds one dispatched command — `ShellTool.Bash`,
`FileTool.Read` / `FileTool.Edit` / `FileTool.Update`, `SearchTool.Grep`
/ `SearchTool.Glob` — back to the underlying tool execution. The
bluebook composes the call as a first-class domain event ; the adapter
is the impure layer that actually runs the shell, edits the file, walks
the filesystem. Sibling to `:llm`, `:sms`, `:tts` — same auto-discovered,
bluebook-first shape.

> "the domain will compose the tool call and the adapter runs them"
> — Chris, 2026-05-12

Pure intent meets pure side-effect. Without the adapter, a
`ShellTool.Bash` dispatch is a logged intent (default-to-memory records
it, emits `BashRan`, persists state). With the adapter, the same
dispatch becomes the act.

The 2026-05-12 restructuring split the original flat `Tools` aggregate
into five category aggregates (ShellTool, FileTool, SearchTool, WebTool,
Cascade) ; the `:claude_tool` adapter bindings in `tools.hecksagon`
follow each command to its new aggregate home. The cascade target moved
to `Cascade.RecordResult` so the outcome chain is its own aggregate,
separating "the act" from "what came back" while sharing the invocation
id for the join.

## The four-piece anatomy

Wiring a Claude-shaped tool into a domain takes four files, each with a
clear role :

```text
  ┌──────────────────────────────────────────────────────────┐
  │ 1. tools.bluebook                                        │
  │    aggregate "Tools" + command "Bash" (intent / shape)   │
  └────────────────────────┬─────────────────────────────────┘
                           │
                           ▼
  ┌──────────────────────────────────────────────────────────┐
  │ 2. tools.hecksagon                                       │
  │    adapter :claude_tool, command: "ShellTool.Bash",      │
  │                          tool: :bash,                    │
  │                          result_into: "Cascade.RecordResult" │
  └────────────────────────┬─────────────────────────────────┘
                           │  (auto-discovered at boot)
                           ▼
  ┌──────────────────────────────────────────────────────────┐
  │ 3. framework/adapter_families/claude_tool.hecksagon      │
  │    Hecks.adapter_family "claude_tool" do                 │
  │      fields :command, :tool, :result_into                │
  │      behavior :invoke_claude_tool                        │
  └────────────────────────┬─────────────────────────────────┘
                           │
                           ▼
  ┌──────────────────────────────────────────────────────────┐
  │ 4. framework/behavior_kinds/invoke_claude_tool.hecksagon │
  │    requires_field :tool, :result_into                    │
  │    (kernel hook : rust/src/runtime/claude_tool_dispatcher.rs)│
  └──────────────────────────────────────────────────────────┘
```

Files 3 and 4 ship in `hecks_conception/aggregates/framework/` — they
declare the family + behavior contract for every consumer. Files 1 and
2 are what you write to use the family in your own aggregate.

## The six tool kinds

| `tool:` | Required attrs | Optional attrs | Result populates |
|---|---|---|---|
| `:bash` | `shell_command` | — | `output`, `exit_code` |
| `:edit` | `file_path`, `old_string` | `new_string`, `replace_all` | `output` (`"edited <path>"`) |
| `:read` | `file_path` | — | `output` (file contents, truncated) |
| `:write` | `file_path` | `content` | `output` (`"wrote N bytes ..."`) |
| `:grep` | `pattern` | `search_path` (defaults to `.`) | `output` (match list) |
| `:glob` | `glob_pattern` | `search_path` (defaults to `.`) | `output` (path list) |

Output capture is capped at 10 KB per dispatch ; longer reads / greps
truncate with a `... [truncated]` footer to keep downstream state
small.

## End-to-end : adding a binding

Concrete recipe — you want to run shell commands from your own
aggregate. Three steps.

### 1. Declare the command in your bluebook

```ruby
# my_domain.bluebook
aggregate "MyDomain" do
  identified_by :id
  attribute :id, Id
  attribute :shell_command, ShellCommand
  attribute :description,   Description

  command "RunCheck" do
    description "Run a sanity check from MyDomain."
    attribute :id,            Id
    attribute :shell_command, ShellCommand
    attribute :description,   Description
    emits "CheckRan"
  end
end
```

(Or, more commonly, dispatch the framework's `ShellTool.Bash` command
directly — see the existing `tools.hecksagon` for the canonical binding
set. The recipe above is the path when you want a domain-named alias.)

### 2. Add the adapter binding

```ruby
# my_domain.hecksagon
Hecks.hecksagon "MyDomain" do
  adapter :memory

  adapter :claude_tool, command: "MyDomain.RunCheck",
                        tool:    :bash,
                        result_into: "MyDomain.RecordResult"
end
```

The four fields :

| Field | Type | Purpose |
|---|---|---|
| `command:` | `"Aggregate.Command"` dotted ref | The dispatched command this adapter listens for. Trigger field. |
| `tool:` | Symbol — one of the six kinds | Which native primitive the kernel runs. |
| `result_into:` | `"Aggregate.Command"` dotted ref | Where the result chains back as a follow-on dispatch. Response field. |
| `name:` | Symbol (optional) | Symbolic adapter name for lookup. |

### 3. Dispatch (when the runtime dispatcher integration lands)

```bash
$ storehouse <root> ShellTool.Bash \
    id="01HX..." \
    shell_command="ls -la" \
    description="list cwd"
```

The bus records the dispatch, emits `BashRan`, the matching
`:claude_tool` adapter fires, the kernel runs `/bin/sh -c "ls -la"`,
captures stdout + exit code, and routes the result into
`Cascade.RecordResult` as a follow-on dispatch (the Cascade record
shares the invocation id with the ShellTool record). Downstream
policies on `BashRan` or `ResultRecorded` (statusline updates,
awareness shifts, mindstream entries) react the same way they react to
any other domain event.

## Runtime status — 2026-05-12

What lands today (i551 + i556) :

- The adapter family bluebook
  (`framework/adapter_families/claude_tool.hecksagon`).
- The behavior_kind bluebook
  (`framework/behavior_kinds/invoke_claude_tool.hecksagon`).
- The six consumer bindings in `framework/tools/tools.hecksagon`.
- The kernel hook
  ([`rust/src/runtime/claude_tool_dispatcher.rs`](../../rust/src/runtime/claude_tool_dispatcher.rs))
  — six native primitives, tested in-module (round-trip on read/write,
  unique-match enforcement on edit, exit-code propagation on bash).

What's pending : the runtime dispatcher arm that walks
`framework/adapter_families/*` at boot, picks up the `:claude_tool`
family typed (instead of falling through to `IoAdapter`), and routes
matching dispatches through the kernel hook. Until that wires through,
the bindings land in the IR as `IoAdapter` rows with
`options={command: "ShellTool.Bash", tool: :bash}` — design surface today,
execution path soon.

## Where the substrate lives — retirement contract

The kernel hook (`claude_tool_dispatcher.rs`) is **kernel-floor today**.
It implements `invoke_claude_tool` directly in Rust because the
framework's general kernel-hook registry doesn't exist yet. Same shape
as `llm_dispatcher.rs` — both are hard-coded handler tables waiting on
the registry.

The retirement contract :

- The dispatcher retires when the framework-wide kernel-hook registry
  lands (filed alongside i551 ; siblings to llm_dispatcher's retirement
  path).
- The adapter family bluebook + behavior_kind bluebook **do not retire** —
  they're the contract, not the implementation. When the registry
  ships, the registry reads them and the hardcoded Rust file goes away.

The adapter contract is also stable across an eventual upgrade : when
the runtime is sophisticated enough to dispatch through Claude tools
for real (rather than mirroring them natively), the kernel hook
changes its execution backend but the family declaration and consumer
bindings stay identical.

## Related

- [`hecks_conception/aggregates/framework/tools/tools.bluebook`](../../hecks_conception/aggregates/framework/tools/tools.bluebook)
  — the Tools aggregate with all six commands.
- [`hecks_conception/aggregates/framework/tools/tools.hecksagon`](../../hecks_conception/aggregates/framework/tools/tools.hecksagon)
  — the canonical binding set, one `:claude_tool` per command.
- [`hecks_conception/aggregates/framework/adapter_families/claude_tool.hecksagon`](../../hecks_conception/aggregates/framework/adapter_families/claude_tool.hecksagon)
  — the family declaration (fields + behavior).
- [`hecks_conception/aggregates/framework/behavior_kinds/invoke_claude_tool.hecksagon`](../../hecks_conception/aggregates/framework/behavior_kinds/invoke_claude_tool.hecksagon)
  — what the kernel does on dispatch.
- [`docs/usage/llm_adapter.md`](llm_adapter.md) — the sibling
  `:llm` adapter family that this mirrors structurally.
- [`hecks_conception/inbox/i551.md`](../../hecks_conception/inbox/i551.md),
  [`hecks_conception/inbox/i552.md`](../../hecks_conception/inbox/i552.md)
  — the design cards.
