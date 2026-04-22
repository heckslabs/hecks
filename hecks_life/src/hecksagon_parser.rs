//! Hecksagon parser — reads .hecksagon files into the Hecksagon IR.
//!
//! Line-oriented, pattern-match style just like the bluebook parser. Not
//! a full Ruby parser — it recognizes the canonical shapes used by the
//! Ruby DSL builder and the files shipped in `capabilities/*.hecksagon`.
//!
//! Canonical shapes handled:
//!
//!   Hecks.hecksagon "Name" do … end
//!   adapter :memory
//!   adapter :stdout / :stderr / :stdin
//!   adapter :env, keys: ["PATH"]
//!   adapter :fs, root: "."
//!   adapter :shell, name: :foo, command: "git …", ok_exit: 0
//!   adapter :shell, name: :foo, command: "git", args: ["log", "{{sha}}"]
//!   gate "Aggregate", :role do allow :CmdA, :CmdB end
//!   subscribe "OtherDomain"
//!
//! Comments (`#`) and blank lines are skipped. Multi-line adapter calls
//! joined until top-level parens balance. Tiny helpers live in
//! hecksagon_helpers.rs so this file stays under the size budget.

use crate::hecksagon_helpers::*;
use crate::hecksagon_ir::*;

/// Lowest-cost source detection. Skips leading blanks and `#` comments
/// and checks the first non-empty line.
pub fn is_hecksagon_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') { continue; }
        return t.starts_with("Hecks.hecksagon");
    }
    false
}

pub fn parse(source: &str) -> Hecksagon {
    let mut hex = Hecksagon::default();
    let source = crate::parser::strip_shebang(source);
    let raw: Vec<&str> = source.lines().collect();

    let mut i = 0;
    while i < raw.len() {
        let line = raw[i].trim();

        if line.starts_with("Hecks.hecksagon") {
            if let Some(n) = between_quotes(line) { hex.name = n; }
            i += 1;
            continue;
        }

        if line.starts_with("subscribe") {
            if let Some(n) = between_quotes(line) { hex.subscriptions.push(n); }
            i += 1;
            continue;
        }

        if line.starts_with("gate ") {
            let (gate, consumed) = parse_gate(&raw[i..]);
            if let Some(g) = gate { hex.gates.push(g); }
            i += consumed;
            continue;
        }

        if line.starts_with("adapter ") || line.starts_with("adapter(") {
            let (joined, consumed) = join_adapter_lines(&raw[i..]);
            absorb_adapter(&joined, &mut hex);
            i += consumed;
            continue;
        }

        i += 1;
    }

    hex
}

/// Take one joined `adapter …` invocation and sort it into the right
/// bucket: persistence, io adapter, or shell adapter.
fn absorb_adapter(joined: &str, hex: &mut Hecksagon) {
    let body = joined.trim()
        .strip_prefix("adapter")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let (kind, rest) = split_first_symbol(body);
    if kind.is_empty() { return; }
    match kind.as_str() {
        "shell" => {
            if let Some(sa) = parse_shell_adapter(rest) { hex.shell_adapters.push(sa); }
        }
        "memory" | "heki" => { hex.persistence = Some(kind); }
        _ => {
            let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
            for ev in extract_on_events(rest) { io.on_events.push(ev); }
            hex.io_adapters.push(io);
        }
    }
}

/// Map `name:, command:, args:, output_format:, timeout:, working_dir:,
/// env:, ok_exit:` into a ShellAdapter. Handles the convenience form
/// `command: "git rev-parse {{ref}}"` (no separate args vector) by
/// splitting on whitespace.
fn parse_shell_adapter(rest: &str) -> Option<ShellAdapter> {
    let mut sa = ShellAdapter { output_format: "text".into(), ok_exit: 0, ..Default::default() };
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => sa.name = strip_symbol(&v),
            "command" => sa.command = strip_quotes(&v),
            "args" => sa.args = parse_string_array(&v),
            "output_format" => sa.output_format = strip_symbol(&v),
            "timeout" => sa.timeout = v.trim().parse::<u64>().ok(),
            "working_dir" => sa.working_dir = Some(strip_quotes(&v)),
            "env" => sa.env = parse_hash_pairs(&v),
            "ok_exit" => sa.ok_exit = v.trim().parse::<i32>().unwrap_or(0),
            _ => {}
        }
    }
    if sa.name.is_empty() || sa.command.is_empty() { return None; }
    if sa.args.is_empty() {
        // Split `command: "git rev-parse {{ref}}"` into command + args.
        let mut tokens = sa.command.split_whitespace();
        if let Some(first) = tokens.next() {
            let rest: Vec<String> = tokens.map(|t| t.to_string()).collect();
            if !rest.is_empty() {
                sa.command = first.to_string();
                sa.args = rest;
            }
        }
    }
    Some(sa)
}

/// `gate "Agg", :role do allow :A, :B end` — single-line or block form.
fn parse_gate(lines: &[&str]) -> (Option<Gate>, usize) {
    let first = lines[0].trim();
    let mut gate = Gate::default();
    if let Some(n) = between_quotes(first) { gate.aggregate = n; }
    if let Some(after) = first.split(',').nth(1) {
        gate.role = strip_symbol(after.trim().trim_end_matches(" do"));
    }
    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if let Some(rest) = t.strip_prefix("allow ") {
            for sym in rest.split(',') {
                let name = strip_symbol(sym.trim());
                if !name.is_empty() { gate.allowed_commands.push(name); }
            }
        }
        i += 1;
    }
    if gate.aggregate.is_empty() { (None, i) } else { (Some(gate), i) }
}

/// Join `adapter …` lines until the parens/brackets balance. Returns
/// the joined one-line form and the number of source lines consumed.
fn join_adapter_lines(lines: &[&str]) -> (String, usize) {
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    for line in lines {
        let t = line.trim();
        consumed += 1;
        if t.is_empty() || t.starts_with('#') {
            if !joined.is_empty() && depth > 0 { continue; }
            if joined.is_empty() { continue; }
            continue;
        }
        if !joined.is_empty() { joined.push(' '); }
        joined.push_str(t);
        let mut prev = '\0';
        for c in t.chars() {
            match c {
                '"' if prev != '\\' => in_str = !in_str,
                '(' | '[' | '{' if !in_str => depth += 1,
                ')' | ']' | '}' if !in_str => depth -= 1,
                _ => {}
            }
            prev = c;
        }
        let ends_comma = t.trim_end().ends_with(',');
        if depth <= 0 && !ends_comma { break; }
    }
    (joined, consumed)
}
