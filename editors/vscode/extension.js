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

/** @returns {string} */
function resolveServerPath() {
  const configured = vscode.workspace.getConfiguration("hecks").get("lsp.serverPath");
  if (configured) {
    return configured;
  }

  // rust/lsp's own README documents this exact lookup order for
  // hecks-parse (its own PATH -> $HECKS_PARSE_BIN -> relative sibling
  // build); mirrored here for hecks-lsp itself, one level up, since
  // there's no equivalent env var a VS Code extension host would
  // already have set.
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    for (const profile of ["debug", "release"]) {
      const guess = path.join(folders[0].uri.fsPath, "rust", "lsp", "target", profile, "hecks-lsp");
      if (fs.existsSync(guess)) {
        return guess;
      }
    }
  }

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
