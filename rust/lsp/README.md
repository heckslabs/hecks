# hecks-lsp

A minimal Language Server Protocol front end for `.bluebook`/`.hecksagon`
files. It doesn't parse anything itself — it shells out to `rust/parser`'s
own `hecks-parse` binary and turns whatever that says into
`textDocument/publishDiagnostics` notifications. See `src/main.rs`'s and
`src/diagnostics.rs`'s own header comments for the reasoning; this file
is setup + roadmap.

## What it does today

- `initialize` / `initialized` / `shutdown` / `exit`
- `textDocument/didOpen` / `didChange` (full sync) / `didSave` / `didClose`
- On every one of those, stages the buffer to a scratch file and runs
  `hecks-parse chapter --chapter <Name> <scratch file>`, where `<Name>`
  is scraped from the buffer's own `Hecks.bluebook "Name"` /
  `Hecks.hecksagon "Name"` line. A clean parse publishes an empty
  diagnostics list; a failure publishes exactly one `Diagnostic`
  (`rust/parser` stops at the first error, so there is never more than
  one to report — see `diagnostics.rs`).
- Diagnostics carry the parser's real message and its `expected one of:
  ...` list, at `severity: Warning` when the cause is
  `not_yet_implemented` (a real Stage 1 gap, not a bug in your file) and
  `severity: Error` otherwise.
- `textDocument/documentSymbol` — an outline of every
  `aggregate`/`entity`/`value_object`/`command`/`query`/`policy`/
  `process_manager`/`read_model` in the open file, nested by `do`/`end`
  depth. Sourced from a text scan of the buffer (`outline.rs`), not from
  `hecks-parse`'s own IR — see that file's header for why (short version:
  the IR carries no source line for anything, and often fails to build
  at all under Stage 1's still-partial coverage, so this needed to work
  independently of a parse succeeding).
- `textDocument/definition` — resolves the bare identifier under the
  cursor (a `reference_to Customer` / `belongs_to Account` usage) to
  wherever that aggregate/entity/value_object is actually declared,
  first in the same file, then across sibling `.bluebook`/`.hecksagon`
  files in the same directory (a chapter routinely spans several files —
  `parse::chapter`'s own header — and the declaration is often in one of
  them, not the file doing the referencing).

## What it doesn't do yet

- **`documentSymbol`/`definition` are text-scanned, not grammar-verified.**
  Real, but a second, unverified idea of the grammar rather than a
  projection of `syntax.bluebook` the way `rust/parser`'s own
  `keywords.rs` is — see `outline.rs`'s header for the reasoning and its
  one real failure mode (a buffer with unbalanced `do`/`end` mid-edit).
  Only `aggregate`/`entity`/`value_object` names are valid `definition`
  targets (`outline::is_reference_target`) — a `command`/`query` name
  is never referenced by a bare identifier elsewhere in the corpus the
  way a type name is, so it isn't one.
- **No column info.** `rust/parser`'s own `Diagnostic` only tracks a
  line, so every diagnostic underlines the whole line. Real squiggle
  precision needs `rust/parser` to track columns first — nothing to fix
  here until then.
- **No completion, hover, or go-to-definition.** The parser's four gates
  (`rust/parser/src/parse/mod.rs`: shape → word → body → argument)
  already encode "what's legal at this point in the grammar" — that's
  exactly what a completion engine needs, but it's not exposed as
  anything this crate can call today. The clean way to add it, in
  keeping with `rust/parser` staying a bin-only, subprocess-only sibling
  (see `diagnostics.rs`'s header): add a new `hecks-parse` subcommand
  (e.g. `hecks-parse complete --chapter <Name> <file> --line N --col N`)
  that runs the same gates up to the cursor and prints the legal next
  words as JSON, the same shape `run_coverage` already prints its list
  in. Once that exists, wiring `textDocument/completion` here is a small
  addition, not a redesign.
- **Only one diagnostic per document.** Inherited from `rust/parser`'s
  own fail-fast design (`parse::chapter`'s doc comment: "Stops at the
  FIRST diagnostic"). If that ever becomes a `Vec<Diagnostic>`, this
  crate's `diagnostics::run` only needs to return `Vec<FileDiagnostic>`
  instead of `Option<FileDiagnostic>` — `main.rs` already publishes
  whatever list it's handed.
- **Single-file chapters only.** A chapter split across multiple
  `.bluebook` files, or paired with a `.hecksagon` file
  (`parse::chapter`'s own header describes both), is only ever checked
  one file at a time here. Fine for every example under `examples/*/`
  today; would need this crate to also track a project's file layout
  (which files share a chapter name) to do better.

## Building it

```
cd rust/parser && cargo build   # produces target/debug/hecks-parse
cd rust/lsp    && cargo build   # produces target/debug/hecks-lsp
```

`hecks-lsp` looks for `hecks-parse` in this order: `$HECKS_PARSE_BIN`,
then `$PATH`, then `../parser/target/{debug,release}/hecks-parse`
relative to wherever it's launched from (the common case while both
crates are built side by side out of one checkout). If none of those
resolve, it still runs — every document just gets an empty diagnostics
list and one `window/logMessage` warning explaining why.

## Wiring it into an editor

**Neovim** (`nvim-lspconfig`, manual server since this isn't a published
server yet):

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "ruby" }, -- .bluebook/.hecksagon have no LSP-registered
                         -- filetype of their own yet; match on extension
                         -- instead if you've set one up, or broaden this
  callback = function(args)
    local fname = vim.api.nvim_buf_get_name(args.buf)
    if not (fname:match("%.bluebook$") or fname:match("%.hecksagon$")) then
      return
    end
    vim.lsp.start({
      name = "hecks-lsp",
      cmd = { "/absolute/path/to/rust/lsp/target/debug/hecks-lsp" },
      root_dir = vim.fs.dirname(fname),
    })
  end,
})
```

**VS Code**: `editors/vscode/` (repo root) is a minimal real extension —
see its own README for build/install steps. Not published to the
marketplace; installed locally (copy into your extensions directory, or
F5 an Extension Development Host). It contributes no syntax highlighting
grammar (a separate gap — see the top-level tooling report), just the
language client wiring.

## Testing it without an editor

`cargo test` covers the pure functions (`chapter_name` extraction,
`Diagnostic` line parsing, JSON round-tripping). For a full stdio
round-trip, speak Content-Length-framed JSON-RPC to the process
directly — `initialize` → `initialized` → `textDocument/didOpen` with a
real `.bluebook`'s text → read the `publishDiagnostics` notification
that comes back.
