//! `hecks-lsp`: a minimal stdio language server for `.bluebook`/`.hecksagon` files.
//! Publishes diagnostics from `hecks-parse chapter` and serves document symbols and definitions.

mod diagnostics;
mod json;
mod outline;
mod rpc;

use json::Json;
use std::collections::HashMap;
use std::io::{self, BufReader, Write};
use std::path::{Path, PathBuf};

struct Server {
    hecks_parse: Option<PathBuf>,
    /// Set once the missing-parser warning is logged, so `didChange` does not repeat it.
    warned_missing_parser: bool,
    documents: HashMap<String, String>,
}

fn main() {
    let mut server = Server {
        hecks_parse: diagnostics::locate_hecks_parse(),
        warned_missing_parser: false,
        documents: HashMap::new(),
    };

    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let stdout = io::stdout();
    let mut writer = stdout.lock();

    loop {
        match rpc::read_message(&mut reader) {
            Ok(Some(message)) => {
                if !server.handle(&message, &mut writer) {
                    break;
                }
            }
            Ok(None) => break,
            Err(e) => {
                eprintln!("hecks-lsp: {e}");
                break;
            }
        }
    }
}

impl Server {
    /// Returns `false` when the server should stop.
    fn handle(&mut self, message: &Json, out: &mut impl Write) -> bool {
        let method = message.get("method").and_then(Json::as_str).unwrap_or("");
        let id = message.get("id").cloned();

        match method {
            "initialize" => {
                if let Some(id) = id {
                    let result = Json::object(vec![
                        (
                            "capabilities",
                            Json::object(vec![
                                // Full sync (1): the client resends the whole body on each change.
                                ("textDocumentSync", Json::Number(1)),
                                ("documentSymbolProvider", Json::Bool(true)),
                                ("definitionProvider", Json::Bool(true)),
                            ]),
                        ),
                        (
                            "serverInfo",
                            Json::object(vec![
                                ("name", Json::string("hecks-lsp")),
                                ("version", Json::string(env!("CARGO_PKG_VERSION"))),
                            ]),
                        ),
                    ]);
                    let _ = rpc::write_message(out, &rpc::response(id, result));
                }
                if self.hecks_parse.is_none() {
                    self.warn_missing_parser(out);
                }
            }
            "initialized" => {}
            "shutdown" => {
                if let Some(id) = id {
                    let _ = rpc::write_message(out, &rpc::response(id, Json::Null));
                }
            }
            "exit" => return false,
            "textDocument/didOpen" => {
                if let Some(doc) = message.get("params").and_then(|p| p.get("textDocument")) {
                    if let (Some(uri), Some(text)) =
                        (doc.get("uri").and_then(Json::as_str), doc.get("text").and_then(Json::as_str))
                    {
                        self.documents.insert(uri.to_string(), text.to_string());
                        self.check_document(uri, out);
                    }
                }
            }
            "textDocument/didChange" => {
                let params = message.get("params");
                let uri = params
                    .and_then(|p| p.get("textDocument"))
                    .and_then(|t| t.get("uri"))
                    .and_then(Json::as_str);
                // Full sync means exactly one change entry, the whole body.
                let text = params
                    .and_then(|p| p.get("contentChanges"))
                    .and_then(Json::as_array)
                    .and_then(|changes| changes.first())
                    .and_then(|c| c.get("text"))
                    .and_then(Json::as_str);
                if let (Some(uri), Some(text)) = (uri, text) {
                    self.documents.insert(uri.to_string(), text.to_string());
                    self.check_document(uri, out);
                }
            }
            "textDocument/didSave" => {
                if let Some(uri) = message
                    .get("params")
                    .and_then(|p| p.get("textDocument"))
                    .and_then(|t| t.get("uri"))
                    .and_then(Json::as_str)
                {
                    self.check_document(uri, out);
                }
            }
            "textDocument/documentSymbol" => {
                if let Some(id) = id {
                    let uri = message
                        .get("params")
                        .and_then(|p| p.get("textDocument"))
                        .and_then(|t| t.get("uri"))
                        .and_then(Json::as_str);
                    let result = match uri.and_then(|u| self.documents.get(u)) {
                        Some(text) => {
                            Json::Array(outline::outline(text).iter().map(document_symbol_json).collect())
                        }
                        None => Json::Array(Vec::new()),
                    };
                    let _ = rpc::write_message(out, &rpc::response(id, result));
                }
            }
            "textDocument/definition" => {
                if let Some(id) = id {
                    let result = self.find_definition(message).unwrap_or(Json::Null);
                    let _ = rpc::write_message(out, &rpc::response(id, result));
                }
            }
            "textDocument/didClose" => {
                if let Some(uri) = message
                    .get("params")
                    .and_then(|p| p.get("textDocument"))
                    .and_then(|t| t.get("uri"))
                    .and_then(Json::as_str)
                {
                    self.documents.remove(uri);
                    publish_diagnostics(out, uri, Vec::new());
                }
            }
            "" => {}
            other => {
                if let Some(id) = id {
                    let _ = rpc::write_message(
                        out,
                        &rpc::error_response(id, -32601, &format!("method not found: {other}")),
                    );
                }
                // Only requests owe a reply; unhandled notifications are ignored.
            }
        }
        true
    }

    fn warn_missing_parser(&mut self, out: &mut impl Write) {
        if self.warned_missing_parser {
            return;
        }
        self.warned_missing_parser = true;
        log(
            out,
            2,
            "hecks-lsp: could not find the `hecks-parse` binary (checked $HECKS_PARSE_BIN, \
             $PATH, and ../parser/target/{debug,release}/hecks-parse relative to the cwd this \
             server was launched from). Diagnostics are disabled until it's built — see \
             rust/parser's own README for `cargo build`.",
        );
    }

    fn check_document(&mut self, uri: &str, out: &mut impl Write) {
        let Some(text) = self.documents.get(uri).cloned() else {
            return;
        };
        let Some(hecks_parse) = self.hecks_parse.clone() else {
            self.warn_missing_parser(out);
            return;
        };

        let temp_path = temp_path_for(uri);
        if let Some(parent) = temp_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&temp_path, &text) {
            log(out, 1, &format!("hecks-lsp: could not stage {}: {e}", temp_path.display()));
            return;
        }

        match diagnostics::run(&hecks_parse, &temp_path, &text) {
            Ok(Some(diag)) => publish_diagnostics(out, uri, vec![lsp_diagnostic(&diag, &text)]),
            Ok(None) => publish_diagnostics(out, uri, Vec::new()),
            Err(e) => log(out, 1, &format!("hecks-lsp: {e}")),
        }
    }

    /// Resolves the identifier under the cursor to its declaration in this buffer,
    /// then in sibling `.bluebook`/`.hecksagon` files, since a chapter spans several files.
    fn find_definition(&self, message: &Json) -> Option<Json> {
        let params = message.get("params")?;
        let uri = params.get("textDocument")?.get("uri")?.as_str()?;
        let position = params.get("position")?;
        let line = position.get("line")?.as_i64()? as usize;
        let character = position.get("character")?.as_i64()? as usize;

        let text = self.documents.get(uri)?;
        let line_text = text.lines().nth(line)?;
        let identifier = identifier_at(line_text, character)?;

        let local_roots = outline::outline(text);
        if let Some(symbol) = outline::find_by_name(&local_roots, &identifier) {
            return Some(location(uri, symbol.start_line));
        }

        let path = uri_to_path(uri)?;
        let dir = path.parent()?;
        let mut siblings: Vec<PathBuf> = std::fs::read_dir(dir)
            .ok()?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                *p != path
                    && matches!(p.extension().and_then(|e| e.to_str()), Some("bluebook") | Some("hecksagon"))
            })
            .collect();
        // Sorted so a name declared in several siblings resolves deterministically.
        siblings.sort();

        for sibling in siblings {
            let Ok(sibling_text) = std::fs::read_to_string(&sibling) else { continue };
            let roots = outline::outline(&sibling_text);
            if let Some(symbol) = outline::find_by_name(&roots, &identifier) {
                return Some(location(&path_to_uri(&sibling), symbol.start_line));
            }
        }
        None
    }
}

/// The `[A-Za-z0-9_]` word touching 0-indexed offset `character`, including at its edges.
fn identifier_at(line_text: &str, character: usize) -> Option<String> {
    let chars: Vec<char> = line_text.chars().collect();
    let is_ident = |c: char| c.is_ascii_alphanumeric() || c == '_';

    let mut start = character;
    if start >= chars.len() || !is_ident(chars[start]) {
        if start > 0 && is_ident(chars[start - 1]) {
            start -= 1;
        } else {
            return None;
        }
    }
    while start > 0 && is_ident(chars[start - 1]) {
        start -= 1;
    }
    let mut end = start;
    while end < chars.len() && is_ident(chars[end]) {
        end += 1;
    }
    Some(chars[start..end].iter().collect())
}

/// A zero-width `Location` at the declaring line; the outline is line-based, so no column.
fn location(uri: &str, line_1_indexed: usize) -> Json {
    let line0 = line_1_indexed.saturating_sub(1) as i64;
    let point = Json::object(vec![("line", Json::Number(line0)), ("character", Json::Number(0))]);
    Json::object(vec![
        ("uri", Json::string(uri)),
        ("range", Json::object(vec![("start", point.clone()), ("end", point)])),
    ])
}

fn document_symbol_json(symbol: &outline::Symbol) -> Json {
    let start0 = symbol.start_line.saturating_sub(1) as i64;
    let end0 = symbol.end_line.max(symbol.start_line).saturating_sub(1) as i64;
    let range = Json::object(vec![
        ("start", Json::object(vec![("line", Json::Number(start0)), ("character", Json::Number(0))])),
        ("end", Json::object(vec![("line", Json::Number(end0)), ("character", Json::Number(0))])),
    ]);
    Json::object(vec![
        ("name", Json::string(symbol.name.clone())),
        ("kind", Json::Number(lsp_symbol_kind(symbol.kind))),
        ("range", range.clone()),
        ("selectionRange", range),
        ("children", Json::Array(symbol.children.iter().map(document_symbol_json).collect())),
    ])
}

/// Maps a construct to an LSP `SymbolKind` number by how it reads in an outline.
fn lsp_symbol_kind(kind: outline::Kind) -> i64 {
    use outline::Kind::*;
    match kind {
        Aggregate => 5,      // Class
        ProcessManager => 5, // Class
        Entity => 23,        // Struct
        ValueObject => 23,   // Struct
        ReadModel => 23,     // Struct
        Command => 6,        // Method
        Query => 12,         // Function
        Policy => 11,        // Interface
    }
}

/// Handles only plain `file://` URIs without percent-escapes.
fn uri_to_path(uri: &str) -> Option<PathBuf> {
    uri.strip_prefix("file://").map(PathBuf::from)
}

fn path_to_uri(path: &Path) -> String {
    format!("file://{}", path.display())
}

fn publish_diagnostics(out: &mut impl Write, uri: &str, diagnostics: Vec<Json>) {
    let params = Json::object(vec![
        ("uri", Json::string(uri)),
        ("diagnostics", Json::Array(diagnostics)),
    ]);
    let _ = rpc::write_message(out, &rpc::notification("textDocument/publishDiagnostics", params));
}

fn log(out: &mut impl Write, severity: i64, message: &str) {
    let params = Json::object(vec![("type", Json::Number(severity)), ("message", Json::string(message))]);
    let _ = rpc::write_message(out, &rpc::notification("window/logMessage", params));
}

/// Builds a full-line diagnostic: Warning when not yet implemented, else Error.
/// The `expected` list is folded into the message text.
fn lsp_diagnostic(diag: &diagnostics::FileDiagnostic, text: &str) -> Json {
    let zero_based_line = diag.line.saturating_sub(1) as i64;
    let line_len = text
        .lines()
        .nth(diag.line.saturating_sub(1))
        .map(|l| l.chars().count() as i64)
        .unwrap_or(0)
        .max(1);

    let mut message = diag.message.clone();
    if !diag.expected.is_empty() {
        message.push_str(&format!(" (expected one of: {})", diag.expected.join(", ")));
    }

    Json::object(vec![
        (
            "range",
            Json::object(vec![
                (
                    "start",
                    Json::object(vec![("line", Json::Number(zero_based_line)), ("character", Json::Number(0))]),
                ),
                (
                    "end",
                    Json::object(vec![
                        ("line", Json::Number(zero_based_line)),
                        ("character", Json::Number(line_len)),
                    ]),
                ),
            ]),
        ),
        // 1 = Error, 2 = Warning (LSP DiagnosticSeverity).
        ("severity", Json::Number(if diag.not_yet_implemented { 2 } else { 1 })),
        ("source", Json::string("hecks-parse")),
        ("message", Json::string(message)),
    ])
}

/// A stable scratch path per URI under the temp dir, since `hecks-parse` reads only from disk.
///
/// Keyed by a hash of the full URI so same-named files from different directories do not collide.
fn temp_path_for(uri: &str) -> PathBuf {
    let hash = fnv1a(uri.as_bytes());
    let basename = uri.rsplit('/').next().unwrap_or("buffer.bluebook");
    std::env::temp_dir().join("hecks-lsp").join(format!("{hash:016x}-{basename}"))
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
