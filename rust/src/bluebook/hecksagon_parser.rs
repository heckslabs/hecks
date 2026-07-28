//! Hecksagon parser — reads .hecksagon files into the Hecksagon IR.
//! [antibody-exempt: hecksagon_parser.rs — hand-written framework source ; was generated from the hecksagon_parser_shape contract until 2026-06-27, when the self-projection codegen was retired]
//! Hand-written framework source. Was generated from
//! codegen/hecksagon_parser_shape until 2026-06-27, when the self-projection
//! codegen was retired — a .bluebook whose only job is to re-emit imperative
//! Rust captures no domain.
//! Tests:     storehouse/tests/hecksagon_parser_test.rs
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
///
/// Recognises the legacy `Hecks.hecksagon` form AND the Phase 1 adapter-
/// family meta-layer forms (`Hecks.adapter_family` / `Hecks.provider` /
/// `Hecks.behavior_kind`). All four set up a Hecksagon IR ; the meta-
/// layer forms additionally stamp `framework_kind` so the kernel
/// registry can index by kind.
pub fn is_hecksagon_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') { continue; }
        return t.starts_with("Hecks.hecksagon")
            || t.starts_with("Hecks.adapter_family")
            || t.starts_with("Hecks.provider")
            || t.starts_with("Hecks.behavior_kind")
            || t.starts_with("Hecks.family")
            || t.starts_with("Hecks.adapter");
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

        // Phase 1 of adapter-family activation : the meta-layer top-level
        // forms set both `name` (the family / provider / behavior name)
        // and `framework_kind` (the discriminator). Inner DSL is skipped
        // here ; Phase 2 will capture fields / providers / request_body
        // into a richer payload.
        if line.starts_with("Hecks.adapter_family") {
            if let Some(n) = between_quotes(line) { hex.name = n; }
            hex.framework_kind = Some("adapter_family".to_string());
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.provider") {
            if let Some(n) = between_quotes(line) { hex.name = n; }
            hex.framework_kind = Some("provider".to_string());
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.behavior_kind") {
            if let Some(n) = between_quotes(line) { hex.name = n; }
            hex.framework_kind = Some("behavior_kind".to_string());
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

        // Sprint 14 first-adapter slice — the event-subscription form
        //   adapter "Name" do
        //     driven on "Context::Aggregate.Event" do |event|
        //       dispatch "Context::Aggregate.Command", attr: value
        //     end
        //   end
        // Starts with `adapter "` (quoted name). Captured as a typed
        // DrivenAdapter so the runtime's `resolve_driven_adapters` can
        // fire the follow-on dispatch when the bus publishes the named
        // event. Coexists with the legacy `adapter :symbol, ...` form
        // handled by `absorb_adapter` below ; the two are dispatched on
        // the very first character after `adapter ` (quote vs colon).
        // Sprint 14 — the block-form adapter envelope hosts BOTH
        // `driven on` (event subscriber) AND `driving on` (external
        // trigger : cron / http_post / file_watch) inner forms in one
        // `adapter "Name" do ... end` outer block. The block is parsed
        // twice ; each parser keeps only its own handlers and skips past
        // the OTHER form's blocks so the consumed-line count stays in
        // sync. Empty siblings drop ; mixed blocks emit one of each.
        if line.starts_with("adapter \"") {
            let (driven, consumed_driven) = parse_driven_adapter(&raw[i..]);
            let (driving, _consumed_driving) = parse_driving_adapter(&raw[i..]);
            if let Some(d) = driven {
                if !d.handlers.is_empty() { hex.driven_adapters.push(d); }
            }
            if let Some(d) = driving {
                if !d.handlers.is_empty() { hex.driving_adapters.push(d); }
            }
            i += consumed_driven;
            continue;
        }

        if line.starts_with("adapter ") || line.starts_with("adapter(") {
            let (joined, consumed) = join_adapter_lines(&raw[i..]);
            absorb_adapter(&joined, &mut hex);
            i += consumed;
            continue;
        }

        if line.starts_with("Hecks.family") {
            let (gate, consumed) = parse_family(&raw[i..]);
            if let Some(g) = gate { hex.families.push(g); }
            i += consumed;
            continue;
        }

        if line.starts_with("Hecks.adapter \"") {
            let (gate, consumed) = parse_adapter_decl(&raw[i..]);
            if let Some(g) = gate { hex.adapters.push(g); }
            i += consumed;
            continue;
        }

        // bucket-3 step 2 — the hexagon bind surface
        // `Aggregate::Path.verb("Adapter"[, on: "Event"])`. Its leading FQN varies,
        // so it dispatches on a STRUCTURAL predicate (is_binding_line) rather than a
        // fixed starts_with prefix. Ordered LAST so every keyword line is consumed
        // by an earlier dispatch first ; only genuine bind lines fall through to the
        // predicate. Reuses multiline_block : parse_binding returns
        // (Option<Binding>, 1), always consuming exactly one line.
        if is_binding_line(line) {
            let (gate, consumed) = parse_binding(&raw[i..]);
            if let Some(g) = gate { hex.bindings.push(g); }
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
        "llm" => {
            if let Some(la) = parse_llm_adapter(rest) {
                hex.llm_adapters.push(la);
            } else {
                // Bare `adapter :llm, backend: :claude` form (no name:) —
                // keep backward-compat with existing wake_review /
                // musing_mint hecksagons that route through io_adapter.
                let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
                for ev in extract_on_events(rest) { io.on_events.push(ev); }
                hex.io_adapters.push(io);
            }
        }
        // i220 sub-gap 5 — sibling of `:llm`. Same shape as
        // parse_llm_adapter / fallback to io_adapter when `name:` is
        // absent, so a bare `adapter :compute, root: "."` (if anyone
        // ever writes one) still lands as an io adapter rather than
        // disappearing.
        "compute" => {
            if let Some(ca) = parse_compute_adapter(rest) {
                hex.compute_adapters.push(ca);
            } else {
                let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
                for ev in extract_on_events(rest) { io.on_events.push(ev); }
                hex.io_adapters.push(io);
            }
        }
        "memory" | "heki" => { hex.persistence = Some(kind); }
        // SQL persistence kinds — `adapter :sqlite, db: "app.db"` (and
        // the postgres/mysql siblings) route into persistence with the
        // kind string AND the connection options (db:/host:/user:/name:).
        // Only the kind crosses the canonical-IR parity boundary ; the
        // options are the runtime's SQL-connect concern. Mirrors Ruby's
        // HecksagonBuilder#adapter, which folds these kinds into
        // `@persistence = { type: k }.merge(opts)`.
        "sqlite" | "postgres" | "mysql" => {
            hex.persistence = Some(kind);
            hex.persistence_options = parse_options(rest);
        }
        _ => {
            let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
            for ev in extract_on_events(rest) { io.on_events.push(ev); }
            hex.io_adapters.push(io);
        }
    }
}

/// Map `name:, prompt_template:, model:, max_tokens:, trigger_on:,
/// response_into:, attr:, backend:` into an LlmAdapter. Returns None
/// when no `name:` is declared — that lets the caller fall back to
/// io_adapter routing for the bare `adapter :llm, backend: :X` form
/// already in production.
///
/// i228 — `trigger_on "Aggregate.Command"` decouples the dispatch
/// target that fires the adapter from `response_into` (which routes
/// the LLM's reply). Falls back to `response_into_target` at runtime
/// when absent, preserving the historical self-triggering shape.
fn parse_llm_adapter(rest: &str) -> Option<LlmAdapter> {
    let mut la = LlmAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { la.name = strip_symbol(&v); got_name = true; }
            // prompt_template is a Ruby double-quoted string literal —
            // unescape \n / \t / \\ / \" so canonical_ir emits a value
            // identical to the Ruby parser's. strip_quotes alone left
            // them literal and broke parity (i75 musing_mint heal,
            // 2026-05-02).
            "prompt_template" => la.prompt_template = strip_quotes_unescape(&v),
            "model" => la.model = Some(strip_quotes(&v)),
            "max_tokens" => la.max_tokens = v.trim().parse::<u64>().ok(),
            "trigger_on" => la.trigger_on = Some(strip_quotes(&v)),
            "response_into" => la.response_into_target = Some(strip_quotes(&v)),
            "attr" => la.response_into_attr = Some(strip_symbol(&v)),
            "backend" => la.backend = Some(strip_symbol(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(la)
}

/// i220 sub-gap 5 (compute-adapter-primitive) — parse the named-adapter form
/// `adapter :compute, name: :foo, function: "fn_name", trigger_on:,
/// response_into:, attr:` into a ComputeAdapter. Returns None when
/// `name:` is absent — the caller falls back to io_adapter routing
/// for any bare `:compute` form (forwards-compat, mirrors
/// parse_llm_adapter's contract).
fn parse_compute_adapter(rest: &str) -> Option<ComputeAdapter> {
    let mut ca = ComputeAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { ca.name = strip_symbol(&v); got_name = true; }
            // `function:` is a string identifier (the registry key).
            // Accept symbol form `:summarize_recent_musings` AND
            // string form `"summarize_recent_musings"` — both
            // canonicalize to the bare identifier.
            "function" => {
                let stripped = strip_quotes(&v);
                ca.function_name = if stripped == v { strip_symbol(&v) } else { stripped };
            }
            "trigger_on" => ca.trigger_on = Some(strip_quotes(&v)),
            "response_into" => ca.response_into_target = Some(strip_quotes(&v)),
            "attr" => ca.response_into_attr = Some(strip_symbol(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(ca)
}

/// Map `name:, command:, args:, output_format:, timeout:, working_dir:,
/// env:, ok_exit:` into a ShellAdapter. Handles the convenience form
/// `command: "git rev-parse {{ref}}"` (no separate args vector) by
/// splitting on whitespace.
fn parse_shell_adapter(rest: &str) -> Option<ShellAdapter> {
    let mut sa = ShellAdapter { output_format: "text".into(), ok_exit: 0, ..Default::default() };
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            // Accept both the symbol form (name: :foo) and the string
            // form (name: "foo") and canonicalize to the bare
            // identifier — mirrors the `function` case above so Rust
            // round-trips a quoted name: identically to the Ruby parser
            // (hecksagon-parity : Ruby strips quotes, Rust must too).
            "name" => {
                let stripped = strip_quotes(&v);
                sa.name = if stripped == v { strip_symbol(&v) } else { stripped };
            }
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
    let mut in_allow = false;
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; in_allow = false; i += 1; continue; }
        let body = if let Some(rest) = t.strip_prefix("allow ") {
            Some(rest)
        } else if in_allow {
            Some(t)
        } else {
            None
        };
        if let Some(body_str) = body {
            for sym in body_str.split(',') {
                let name = strip_symbol(sym.trim());
                if !name.is_empty() { gate.allowed_commands.push(name); }
            }
            in_allow = body_str.trim_end().ends_with(',');
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
    let mut idx = 0;
    while idx < lines.len() {
        let t = lines[idx].trim();
        consumed += 1;
        idx += 1;
        if t.is_empty() || t.starts_with('#') {
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
    if joined.trim_end().ends_with(" do") {
        joined = joined.trim_end().trim_end_matches(" do").trim_end().to_string();
        while idx < lines.len() {
            let raw_t = lines[idx];
            consumed += 1;
            idx += 1;
            // Strip trailing `# ...` comment outside string literals,
            // then trim. Without this, a line like
            //     endpoint   "https://api.example.com"   # prod host
            // emitted `endpoint: "https://api.example.com" # ...` and
            // strip_quotes (matches both ends) left the literal quotes
            // intact, which broke downstream URL construction in any
            // adapter consumer that expected a
            // clean value. Inlined here (not pulled into its own helper)
            // to keep the cleanup local — a small self-contained step.
            let cleaned: String = {
                let mut out = String::with_capacity(raw_t.len());
                let mut in_str = false;
                let mut prev = '\0';
                for c in raw_t.chars() {
                    match c {
                        '"' if prev != '\\' => { in_str = !in_str; out.push(c); }
                        '#' if !in_str => break,
                        _ => out.push(c),
                    }
                    prev = c;
                }
                out
            };
            let t = cleaned.trim();
            if t.is_empty() || t.starts_with('#') { continue; }
            if t == "end" { break; }
            if let Some(sp) = t.find(char::is_whitespace) {
                let key = &t[..sp];
                let val = t[sp..].trim();
                joined.push_str(", ");
                joined.push_str(key);
                joined.push_str(": ");
                joined.push_str(val);
            }
        }
    }
    (joined, consumed)
}

/// Sprint 14 first-adapter slice — parse the block form :
///
/// ```text
/// adapter "Name" do
///   driven on "Context::Aggregate.Event" do |event|
///     dispatch "Context::Aggregate.Command", attr: "value"
///   end
/// end
/// ```
///
/// Returns (Some(DrivenAdapter), lines_consumed). When the block is
/// malformed (no name, no closing end) returns None plus a best-effort
/// consumed count so the caller advances past the noise.
fn parse_driven_adapter(lines: &[&str]) -> (Option<DrivenAdapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = DrivenAdapter { name, handlers: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("driven on") {
            let (handler, consumed) = parse_driven_handler(&lines[i..]);
            if let Some(h) = handler { adapter.handlers.push(h); }
            i += consumed;
            continue;
        }
        // Sprint 14 sibling block — skip past `driving on` blocks (the
        // sibling parse_driving_adapter captures them) while keeping the
        // line cursor aligned with the outer parse() loop's consumed
        // count. Without this skip the inner `dispatch` lines inside a
        // driving block would be misinterpreted as standalone tokens.
        if t.starts_with("driving on") {
            let (_, consumed) = parse_driving_handler(&lines[i..]);
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
}

/// Sprint 14 sibling of `parse_driven_adapter` — parses the externally-
/// triggered shape :
///
/// ```text
/// adapter "Name" do
///   driving on cron "*/5 * * * *" do |signal|
///     dispatch "Context::Aggregate.Command", attr: "value"
///   end
/// end
/// ```
///
/// Returns (Some(DrivingAdapter), lines_consumed). When the block is
/// malformed (no name, no closing end) returns None plus a best-effort
/// consumed count so the caller advances past the noise. Mixed adapters
/// (containing both `driven on` and `driving on` blocks) are parsed
/// twice — once into a DrivenAdapter, once here — so callers should
/// push the result into the hecksagon's `driving_adapters` bucket only.
fn parse_driving_adapter(lines: &[&str]) -> (Option<DrivingAdapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = DrivingAdapter { name, handlers: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("driving on") {
            let (handler, consumed) = parse_driving_handler(&lines[i..]);
            if let Some(h) = handler { adapter.handlers.push(h); }
            i += consumed;
            continue;
        }
        // Driven blocks already consumed by parse_driven_adapter on the
        // first pass ; skip past them here without double-handling.
        if t.starts_with("driven on") {
            let (_, consumed) = parse_driven_handler(&lines[i..]);
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
}

/// Parse one `driving on <kind> "<arg>" do |signal| dispatch "X.Y",
/// k: v ... end` block. Returns (Some(DrivingHandler), lines_consumed).
///
/// The grammar reuses `dispatch` for the body, so the inner parser is
/// the same `join_dispatch_lines` + `parse_driven_dispatch` pair the
/// `driven on` form uses. Only the header differs : here we capture
/// `kind` (the first whitespace-delimited token after `driving on`)
/// and `arg` (the first quoted string on the same line).
fn parse_driving_handler(lines: &[&str]) -> (Option<DrivingHandler>, usize) {
    let first = lines[0].trim();
    let after = match first.strip_prefix("driving on") {
        Some(s) => s.trim(),
        None => return (None, 1),
    };
    let kind_end = after.find(|c: char| c.is_whitespace() || c == '"').unwrap_or(after.len());
    let kind = after[..kind_end].trim().to_string();
    if kind.is_empty() { return (None, 1); }
    let arg = between_quotes(after).unwrap_or_default();
    let mut handler = DrivingHandler { kind, arg, dispatches: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(handler), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("dispatch ") || t.starts_with("dispatch(") {
            let (joined, consumed) = join_dispatch_lines(&lines[i..]);
            if let Some(d) = parse_driven_dispatch(&joined) {
                handler.dispatches.push(d);
            }
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(handler), i)
}

/// Parse one `driven on "Event" do |e| dispatch "X.Y", k: v ... end`
/// block. Returns (Some(DrivenHandler), lines_consumed).
fn parse_driven_handler(lines: &[&str]) -> (Option<DrivenHandler>, usize) {
    let first = lines[0].trim();
    let event_ref = match between_quotes(first) { Some(e) => e, None => return (None, 1) };
    let mut handler = DrivenHandler { event_ref, canned: None, dispatches: Vec::new(), runs: Vec::new(), checks: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(handler), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        // Sprint 14 memory-canned-defaults — `canned do ... end` block
        // declares the wrapped-call return value(s) the resolver hands
        // to the follow-on dispatch when no `.world` adapter entry
        // makes this adapter real. The block body is the same k/v shape
        // a hecksagon extension config uses ; `parse_canned_block`
        // collects (key, raw-token) pairs into CannedResponse.values.
        if t == "canned do" || t.starts_with("canned do ") || t.starts_with("canned do;") {
            let (canned, consumed) = parse_canned_block(&lines[i..]);
            if let Some(c) = canned { handler.canned = Some(c); }
            i += consumed;
            continue;
        }
            if t.starts_with("run ") {
                // Extract the command, honoring \" escapes so the .hecksagon
                // stays valid Ruby when the command contains double-quotes
                // (e.g. a gh --jq filter). Scan from the first quote to the
                // first UNescaped quote, translating \" -> ".
                let extracted = t.find('"').and_then(|s0| {
                    let mut out = String::new();
                    let mut rest_idx = t.len();
                    let mut closed = false;
                    let mut it = t.char_indices().filter(|&(i, _)| i > s0).peekable();
                    while let Some((idx, c)) = it.next() {
                        if c == '\\' {
                            if let Some(&(_, '"')) = it.peek() { out.push('"'); it.next(); continue; }
                            out.push('\\');
                            continue;
                        }
                        if c == '"' { closed = true; rest_idx = idx + c.len_utf8(); break; }
                        out.push(c);
                    }
                    if closed { Some((out, rest_idx)) } else { None }
                });
                if let Some((cmd, rest_idx)) = extracted {
                    let rest = &t[rest_idx..];
                    if let Some(ri) = rest.find("result_into:") {
                        match between_quotes(&rest[ri..]) {
                            Some(target) => handler.checks.push(CheckLeaf { cmd, result_into: target }),
                            None => handler.runs.push(cmd),
                        }
                    } else {
                        handler.runs.push(cmd);
                    }
                }
                i += 1;
                continue;
            }
                if t.starts_with("dispatch ") || t.starts_with("dispatch(") {
            let (joined, consumed) = join_dispatch_lines(&lines[i..]);
            if let Some(d) = parse_driven_dispatch(&joined) {
                handler.dispatches.push(d);
            }
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(handler), i)
}

/// Join continuation lines for a `dispatch` call until a top-level
/// non-comma terminator. Mirrors `join_adapter_lines` but stops at the
/// natural end of one call (no `do`/`end` block ; dispatch is a single
/// expression).
fn join_dispatch_lines(lines: &[&str]) -> (String, usize) {
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    for raw in lines.iter() {
        let t = raw.trim();
        consumed += 1;
        if t.is_empty() || t.starts_with('#') {
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

/// Parse a joined `dispatch "FQN", k1: v1, k2: v2` line into a
/// DrivenDispatch. The first quoted string is the command FQN ; the
/// remaining options are the static attrs. Returns None when no FQN.
fn parse_driven_dispatch(joined: &str) -> Option<DrivenDispatch> {
    let body = joined.trim()
        .strip_prefix("dispatch")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let command = between_quotes(body)?;
    // After the first quoted token (`"FQN"`), the attrs start at the
    // following comma. Find that comma at top level and parse the tail
    // as `parse_options` does.
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    let mut split_at: Option<usize> = None;
    for (idx, c) in body.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '(' | '[' | '{' if !in_str => depth += 1,
            ')' | ']' | '}' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => { split_at = Some(idx); break; }
            _ => {}
        }
        prev = c;
    }
    let mut attrs = match split_at {
        Some(idx) => parse_options(body[idx + 1..].trim_end_matches(')').trim()),
        None => Vec::new(),
    };
    // i221-C — a `for_each: { from: "Q", where: {...} }` clause makes this
    // dispatch a sweep. parse_options keeps it as one (brace-aware) pair ;
    // lift it to a ForEachSpec and drop it from the literal attrs.
    let for_each = crate::parse_blocks::parse_for_each_clause(body);
    attrs.retain(|(k, _)| k != "for_each");
    Some(DrivenDispatch { command, attrs, for_each })
}

/// Sprint 14 memory-canned-defaults — parse a `canned do ... end`
/// block inside a `driven on` handler. Captures inner `key value` lines
/// (e.g. `output "ack"`, `exit_code 0`) into CannedResponse.values
/// verbatim ; the resolver translates per-attr at fire time.
fn parse_canned_block(lines: &[&str]) -> (Option<CannedResponse>, usize) {
    let first = lines[0].trim();
    let mut canned = CannedResponse { values: Vec::new() };

    // Inline form : `canned do; output "ack"; exit_code 0 end`
    if first.ends_with("end") && first.contains("do") {
        let body = first
            .trim_start_matches("canned")
            .trim()
            .trim_start_matches("do")
            .trim_start_matches(|c: char| c == ';' || c.is_whitespace())
            .trim_end()
            .trim_end_matches("end")
            .trim();
        for piece in body.split(';') {
            let p = piece.trim();
            if p.is_empty() { continue; }
            if let Some(kv) = parse_canned_kv(p) { canned.values.push(kv); }
        }
        return (Some(canned), 1);
    }

    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(canned), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if let Some(kv) = parse_canned_kv(t) { canned.values.push(kv); }
        i += 1;
    }
    (Some(canned), i)
}

/// Sprint 14 memory-canned-defaults — parse one `key value` line
/// from inside a `canned do ... end` block. Keeps the raw value-token
/// so the resolver's build_attr_map applies the same conversion rule
/// the dispatch attrs already use.
fn parse_canned_kv(line: &str) -> Option<(String, String)> {
    let t = line.trim().trim_end_matches(';');
    let ident_end = t.find(|c: char| !c.is_alphanumeric() && c != '_')?;
    if ident_end == 0 { return None; }
    let key = t[..ident_end].to_string();
    let rest = t[ident_end..].trim().trim_end_matches(';').trim();
    if rest.is_empty() { return None; }
    Some((key, rest.to_string()))
}

/// bucket-3 step 1 — parse one `Hecks.family "name" do verb "v" ;
/// signal :s ; field :f end` block into a Family. Returns the parsed
/// Family and the line count consumed (through the matching `end`).
fn parse_family(lines: &[&str]) -> (Option<Family>, usize) {
        fn sym_after(line: &str, keyword: &str) -> String {
            let rest = match line.strip_prefix(keyword) { Some(r) => r.trim_start(), None => return String::new() };
            let rest = rest.strip_prefix(':').unwrap_or(rest);
            let end = rest.find(|c: char| c.is_whitespace() || c == '#' || c == ',').unwrap_or(rest.len());
            rest[..end].trim().to_string()
        }
        // `field :x, from: :env` -> "env" ; `field :x` -> "direct". The source
        // the declaration FORM carries (secret is handled by its own arm).
        fn source_from_decl(line: &str) -> String {
            if let Some(idx) = line.find("from:") {
                let after = line[idx + "from:".len()..].trim_start();
                let after = after.strip_prefix(':').unwrap_or(after);
                let end = after.find(|c: char| c.is_whitespace() || c == '#' || c == ',').unwrap_or(after.len());
                let s = after[..end].trim();
                if !s.is_empty() { return s.to_string(); }
            }
            "direct".to_string()
        }
        let first = lines[0].trim();
        let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
        let mut family = Family { name, verb: String::new(), signal: String::new(), fields: Vec::new(), produces: Vec::new() };
        let mut i = 1;
        while i < lines.len() {
            let t = lines[i].trim();
            if t == "end" { return (Some(family), i + 1); }
            if t.is_empty() || t.starts_with('#') { i += 1; continue; }
            match t.split_whitespace().next().unwrap_or("") {
                "verb" => { if let Some(v) = between_quotes(t) { family.verb = v; } }
                "signal" => { family.signal = sym_after(t, "signal"); }
                "field" => {
                    let name = sym_after(t, "field");
                    if !name.is_empty() {
                        family.fields.push(FamilyField { name, source: source_from_decl(t) });
                    }
                }
                "secret" => {
                    let name = sym_after(t, "secret");
                    if !name.is_empty() {
                        family.fields.push(FamilyField { name, source: "secret".to_string() });
                    }
                }
                "produces" => {
                    let name = sym_after(t, "produces");
                    if !name.is_empty() { family.produces.push(name); }
                }
                _ => {}
            }
            i += 1;
        }
        (Some(family), i)
    }

/// bucket-3 step 1 — parse one `Hecks.adapter "Name" do family "fam"
/// end` block into an Adapter (the inverted arrow : the adapter
/// declares the family it implements). Returns the Adapter and the
/// line count consumed (through the matching `end`).
fn parse_adapter_decl(lines: &[&str]) -> (Option<Adapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = Adapter { name, family: String::new(), handler: String::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.split_whitespace().next() == Some("family") {
            if let Some(f) = between_quotes(t) { adapter.family = f; }
        }
        if t.split_whitespace().next() == Some("handler") {
            if let Some(h) = between_quotes(t) { adapter.handler = h; }
        }
        i += 1;
    }
    (Some(adapter), i)
}

/// bucket-3 step 2 — true when a line is a hexagon bind
/// `Aggregate::Path.verb(...)`. Structural predicate for the
/// condition_kind: predicate dispatch (the leading FQN varies, so no
/// fixed starts_with prefix fits).
fn is_binding_line(line: &str) -> bool {
    let t = line.trim();
    match t.find("::") {
        Some(idx) if idx > 0 => {
            let head = &t[..idx];
            head.starts_with(|c: char| c.is_ascii_uppercase())
                && head.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && t.contains('.')
                // No `(` requirement : a no-argument directive verb
                // (`Order.event_sourced`, persistence+) is a binding too.
                // The Ruby FqnBindingProxy already records any no-arg verb,
                // so Rust must accept the paren-less form to stay in parity.
        }
        _ => false,
    }
}

/// bucket-3 step 2 — decompose one bind line `aggregate . verb (
/// "adapter" [, on: "event"] )` into a Binding. Returns the Binding and
/// 1 (always consumes a single line, so it slots into multiline_block).
fn parse_binding(lines: &[&str]) -> (Option<Binding>, usize) {
        let t = lines[0].trim();
        let paren = match t.find('(') {
            Some(p) => p,
            None => {
                // A no-argument directive verb (`Pizzas::Order.event_sourced`)
                // — a persistence+ flag with no adapter. Split at the last '.' :
                // the aggregate FQN + the bare verb, every other field empty.
                // Mirrors the Ruby FqnBindingProxy (records any no-arg verb as
                // a Binding with empty adapter), so both parsers agree.
                let dot = match t.rfind('.') { Some(d) => d, None => return (None, 1) };
                let aggregate = t[..dot].trim().to_string();
                let verb = t[dot + 1..].trim().to_string();
                if aggregate.is_empty() || verb.is_empty() { return (None, 1); }
                return (
                    Some(Binding {
                        aggregate,
                        verb,
                        adapter: String::new(),
                        on: String::new(),
                        success: String::new(),
                        failure: String::new(),
                    }),
                    1,
                );
            }
        };
        let head = &t[..paren];
        let dot = match head.rfind('.') { Some(d) => d, None => return (None, 1) };
        let aggregate = head[..dot].trim().to_string();
        let verb = head[dot + 1..].trim().to_string();
        if aggregate.is_empty() || verb.is_empty() { return (None, 1); }
        let args = &t[paren + 1..];
        let adapter = between_quotes(args).unwrap_or_default();
        let on = match args.find("on:") {
            Some(idx) => between_quotes(&args[idx..]).unwrap_or_default(),
            None => String::new(),
        };
        // The effect-port verdict block : `do success "..." failure "..." end`.
        // When the bind line ends with `do`, walk the inner lines collecting the
        // success / failure re-entry commands until the matching `end`. Reply /
        // fulfillment binds have no block — success/failure stay empty, one line.
        let mut success = String::new();
        let mut failure = String::new();
        let mut consumed = 1;
        if t.trim_end().ends_with("do") {
            let mut i = 1;
            while i < lines.len() {
                let b = lines[i].trim();
                i += 1;
                if b == "end" { break; }
                if let Some(rest) = b.strip_prefix("success") {
                    if let Some(v) = between_quotes(rest) { success = v; }
                } else if let Some(rest) = b.strip_prefix("failure") {
                    if let Some(v) = between_quotes(rest) { failure = v; }
                }
            }
            consumed = i;
        }
        (Some(Binding { aggregate, verb, adapter, on, success, failure }), consumed)
}
