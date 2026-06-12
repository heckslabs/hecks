# FileTool.Edit mangles leading whitespace on multi-line old_string

_Found 2026-06-11 during reference_to retirement step 1 (creates marker)._

## Symptom
`Tools::FileTool.Edit` (via `storehouse__dispatch`) returns `old_string not
found` whenever the `old_string` spans multiple lines AND a continuation line
carries leading indentation (e.g. matching a 4-space Ruby method body or a
12/24-space struct-literal field). The SAME edit succeeds when reduced to a
single line, or when the match starts mid-line so no leading whitespace is
involved. Single-line `old_string` with INTERNAL runs of spaces (column
alignment) matches fine — only LEADING whitespace on a newline-prefixed line
is affected.

Reproduced ~6× this session across .rs, .rb, and .fixtures files. Workaround
used throughout : single-line anchors only (struct-literal field order is
free in Rust ; Ruby tolerates injected methods anywhere ; fixture rows are
order-by-attribute not by file position).

## Likely cause
The MCP dispatch stringifies args to `key=value` on the CLI
(`storehouse <dir> <command> k=v`). A newline followed by leading spaces in
the value is most likely collapsed/trimmed by the shell-arg or storehouse
k=v parsing before `old_string` reaches the edit matcher. `new_string`
leading whitespace appears preserved (only the MATCH side fails), so the
damage is on input parsing of `old_string`, not output.

## Fix direction
The FileTool adapter should receive `old_string` / `new_string` as opaque
values that survive newlines+indentation byte-for-byte — e.g. length-prefixed
or base64 transport for the edit args, rather than k=v string splitting.
Until fixed, multi-line edits through the door are unreliable ; this is a
real door bug, not a caller error.
