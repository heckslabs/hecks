//! I/O adapters — :stdout, :stderr, :stdin, :env, :fs
//!
//! Tiny wrappers that give the hecksagon-declared IoAdapter entries a
//! runtime execution surface. Each function is called by the
//! ScriptRunner when a declared adapter needs to fire (event hook or
//! direct dispatch).
//!
//! Placeholder substitution: strings carrying `{{name}}` tokens have
//! them replaced from the attrs map. Unknown placeholders pass through
//! as literal text so debugging stays honest.

use crate::hecksagon_ir::IoAdapter;
use std::collections::HashMap;
use std::io::{self, BufRead, Write};

/// Replace every `{{name}}` token in `s` from `attrs`. Unknown tokens
/// stay verbatim.
pub fn substitute(s: &str, attrs: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 4 <= bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(close) = s[i + 2..].find("}}") {
                let name = &s[i + 2..i + 2 + close];
                if let Some(val) = attrs.get(name) {
                    out.push_str(val);
                } else {
                    out.push_str(&s[i..i + 2 + close + 2]);
                }
                i += 2 + close + 2;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// Write `text` (with placeholders substituted) to stdout followed by a
/// newline. The adapter may carry an `options` pair like
/// `template: "  ❄ {{msg}}"`.
pub fn write_stdout(adapter: &IoAdapter, text: &str, attrs: &HashMap<String, String>) {
    let template = find_option(adapter, "template").unwrap_or("{{text}}");
    let mut merged = attrs.clone();
    merged.entry("text".to_string()).or_insert_with(|| text.to_string());
    let line = substitute(template, &merged);
    let stdout = io::stdout();
    let mut h = stdout.lock();
    let _ = writeln!(h, "{}", line);
    let _ = h.flush();
}

/// Write to stderr. Same templating as stdout.
pub fn write_stderr(adapter: &IoAdapter, text: &str, attrs: &HashMap<String, String>) {
    let template = find_option(adapter, "template").unwrap_or("{{text}}");
    let mut merged = attrs.clone();
    merged.entry("text".to_string()).or_insert_with(|| text.to_string());
    let line = substitute(template, &merged);
    let _ = writeln!(io::stderr(), "{}", line);
}

/// Blocking line read from stdin. Returns `None` on EOF (ctrl-d). The
/// prompt option is written to stdout before reading so the terminal
/// adapter can ship `prompt: "  ❄ "`.
pub fn read_stdin_line(adapter: &IoAdapter) -> Option<String> {
    if let Some(prompt) = find_option(adapter, "prompt") {
        print!("{}", prompt);
        let _ = io::stdout().flush();
    }
    let stdin = io::stdin();
    let mut line = String::new();
    match stdin.lock().read_line(&mut line) {
        Ok(0) => None,
        Ok(_) => Some(line.trim_end_matches(['\r', '\n']).to_string()),
        Err(_) => None,
    }
}

/// Read selected environment variables into a map. The adapter declares
/// `keys: ["KEY1", "KEY2"]`; missing keys resolve to empty strings.
pub fn read_env(adapter: &IoAdapter) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for k in parse_string_array_option(adapter, "keys") {
        out.insert(k.clone(), std::env::var(&k).unwrap_or_default());
    }
    out
}

/// Read a file whose path has placeholders substituted from `attrs`.
/// Errors are returned as an empty string so scripts can branch on
/// presence without panicking. The :fs adapter's `root:` option, when
/// present, is prepended to the substituted path unless it's already
/// absolute.
pub fn read_fs_file(adapter: &IoAdapter, path: &str, attrs: &HashMap<String, String>) -> String {
    let sub = substitute(path, attrs);
    let full = match find_option(adapter, "root") {
        Some(root) if !sub.starts_with('/') => format!("{}/{}", root.trim_end_matches('/'), sub),
        _ => sub,
    };
    std::fs::read_to_string(&full).unwrap_or_default()
}

fn find_option<'a>(adapter: &'a IoAdapter, key: &str) -> Option<&'a str> {
    adapter.options.iter().find(|(k, _)| k == key)
        .map(|(_, v)| v.trim_matches('"').trim_start_matches('[').trim_end_matches(']'))
}

fn parse_string_array_option(adapter: &IoAdapter, key: &str) -> Vec<String> {
    let raw = match adapter.options.iter().find(|(k, _)| k == key) {
        Some((_, v)) => v.as_str(),
        None => return vec![],
    };
    let t = raw.trim().trim_start_matches('[').trim_end_matches(']');
    t.split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}
