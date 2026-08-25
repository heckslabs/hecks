// The VS Code side of hecks-lsp: a thin client that spawns rust/lsp's
// `hecks-lsp` over stdio and hands it every open `.bluebook`/
// `.hecksagon` file. All the real logic (diagnostics, documentSymbol,
// definition) lives server-side in rust/lsp — see that crate's own
// README for what it does and doesn't support yet. This file's only
// job is finding the server binary and wiring vscode-languageclient to
// it; no bundler, no TypeScript build step, plain CommonJS.

const fs = require("fs");
const path = require("path");
const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

/**
 * Walks upward from `startDir` toward the filesystem root, checking at
 * every level for a built `hecks-lsp` — handles both a workspace folder
 * that IS the repo root (matches on the first try) and one opened
 * several directories below it, without needing to know the checkout's
 * own depth.
 * @returns {string | undefined}
 */
function findServerUpwardFrom(startDir) {
  let dir = startDir;
  for (;;) {
    for (const profile of ["debug", "release"]) {
      const guess = path.join(dir, "rust", "lsp", "target", profile, "hecks-lsp");
      if (fs.existsSync(guess)) {
        return guess;
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      return undefined; // reached the filesystem root
    }
    dir = parent;
  }
}

/** @returns {string} */
function resolveServerPath() {
  const configured = vscode.workspace.getConfiguration("hecks").get("lsp.serverPath");
  if (configured) {
    return configured;
  }

  // Two sources of a starting directory, tried in order: every open
  // workspace folder, then the ACTIVE FILE's own directory. The second
  // one matters more than it looks — opening a single `.bluebook` file
  // with File > Open File (no folder open at all) is a completely
  // ordinary way to try this out, and leaves `workspaceFolders` empty;
  // without this, that case silently falls through to the bare
  // `hecks-lsp` $PATH lookup below and fails with ENOENT (confirmed:
  // that's exactly what happened testing this against a loose file).
  const candidates = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  if (vscode.window.activeTextEditor) {
    candidates.push(path.dirname(vscode.window.activeTextEditor.document.uri.fsPath));
  }
  for (const start of candidates) {
    const found = findServerUpwardFrom(start);
    if (found) {
      return found;
    }
  }

  // rust/lsp's own README documents this exact lookup order for
  // hecks-parse (its own PATH -> $HECKS_PARSE_BIN -> relative sibling
  // build); this is the equivalent last resort for hecks-lsp itself.
  return "hecks-lsp"; // fall back to $PATH
}

function activate(context) {
  const command = resolveServerPath();
  const hecksParseBin = vscode.workspace.getConfiguration("hecks").get("parse.binaryPath");

  const serverOptions = {
    command,
    transport: TransportKind.stdio,
    options: hecksParseBin ? { env: { ...process.env, HECKS_PARSE_BIN: hecksParseBin } } : undefined,
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "hecks-bluebook" }],
    outputChannelName: "Hecks Language Server",
  };

  client = new LanguageClient("hecksLsp", "Hecks Language Server", serverOptions, clientOptions);
  context.subscriptions.push(client.start());
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
