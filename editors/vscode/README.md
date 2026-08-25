# Hecks Language Support (VS Code)

A thin client that wires VS Code to `rust/lsp`'s `hecks-lsp` for
`.bluebook`/`.hecksagon` files. All the real behavior — diagnostics,
`documentSymbol`, `definition` — lives server-side; see
`rust/lsp/README.md` for what it does and doesn't support yet.

**Syntax highlighting is real Ruby's**, not a second, hand-maintained
grammar: `.bluebook`/`.hecksagon` files are literal Ruby, so
`syntaxes/hecks-bluebook.tmLanguage.json` just includes VS Code's own
built-in `source.ruby` grammar under our own scope name. Every real
Ruby token (`do`/`end`, strings, symbols, comments, string
interpolation) colors correctly with nothing here to fall out of sync
as Ruby's own grammar improves upstream. `language-configuration.json`
(bracket matching, comment toggling, `do`/`end`-aware indentation) is
copied from VS Code's own bundled Ruby extension for the same reason.

**If files still open in a different language mode** (most likely
Ruby) — check your own `files.associations` setting
(`Cmd+,` → search "file associations", or global `settings.json`
directly). A `"*.bluebook": "ruby"` entry from before this extension
existed will always beat this extension's own language contribution;
either remove it or switch the language mode per file (bottom-right
status bar, or `Cmd+K M`).

## 1. Build the server

```
cd ../../rust/parser && cargo build
cd ../lsp            && cargo build
```

(`--release` works too — the extension checks both `target/debug/` and
`target/release/`.)

## 2. Install this extension's own dependency

```
cd editors/vscode
npm install
```

## 3. Try it, without installing anything globally

Open `editors/vscode/` as its own folder in VS Code and press F5 (or
Run → Start Debugging). That launches an Extension Development Host
window with this extension active — open any `.bluebook`/`.hecksagon`
file in a workspace that has `rust/lsp/target/{debug,release}/hecks-lsp`
built (step 1) and it activates automatically.

## 4. Or install it for real, locally

There's no marketplace listing — copy (or symlink) this folder into
your extensions directory and reload:

```
cp -r editors/vscode "$HOME/.vscode/extensions/hecks-lsp-client-0.1.0"
cd "$HOME/.vscode/extensions/hecks-lsp-client-0.1.0" && npm install
```

Then reload VS Code (Cmd+Shift+P → "Developer: Reload Window").

## Settings

Both are optional — the defaults match a normal `cargo build` done
right in this checkout (see step 1):

- `hecks.lsp.serverPath` — absolute path to `hecks-lsp`. Empty searches
  `$PATH`, then `rust/lsp/target/{debug,release}/hecks-lsp` relative to
  the first workspace folder.
- `hecks.parse.binaryPath` — absolute path to `hecks-parse`, passed to
  `hecks-lsp` as `$HECKS_PARSE_BIN`. Empty lets `hecks-lsp` find it
  itself (its own README documents that lookup order).

## Checking it's actually working

Open a real corpus file (`examples/pizzas/bluebook/pizzas.bluebook`) —
the View → Output panel's "Hecks Language Server" channel should show
the client starting with no errors. Break the file (misspell a keyword)
and save — a red squiggle should appear with `hecks-parse`'s own error
message on hover. Cmd-click (or F12) on a `reference_to`/`belongs_to`
target should jump to its declaration, including across files in the
same directory.
