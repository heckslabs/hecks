//! Hecksagon parser — reads .hecksagon files into the Hecksagon IR.
//!
//! GENERATED FILE — do not edit.
//! Source:    codegen/hecksagon_parser_shape/
//! Regenerate: storehouse specialize hecksagon_parser --output storehouse/src/hecksagon_parser.rs
//! Contract:  storehouse/src/specializer/hecksagon_parser.rs (Rust-native)
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
            || t.starts_with("Hecks.behavior_kind");
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
        if line.starts_with("adapter \"") {
            let (gate, consumed) = parse_driven_adapter(&raw[i..]);
            if let Some(g) = gate { hex.driven_adapters.push(g); }
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

    // Default persistence to "memory" when no persistence adapter was
    // declared. The IR consumers have always treated None as "memory"
    // by convention ; normalising here removes the None possibility
    // from downstream code paths so the field is always a concrete
    // value. Keeps hecksagons that don't declare `adapter :memory`
    // (the default) equivalent to ones that do — eliminates the
    // redundant-declaration noise without introducing a None
    // representation.
    if hex.persistence.is_none() {
        hex.persistence = Some("memory".to_string());
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
        // i-tts — sibling of `:llm` / `:compute`. Named form parses
        // into a typed TtsAdapter ; a bare `adapter :tts, provider: :x`
        // (no name:) falls back to io_adapter, same forwards-compat
        // contract as the compute arm above.
        "tts" => {
            if let Some(ta) = parse_tts_adapter(rest) {
                hex.tts_adapters.push(ta);
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

/// i-tts — sibling of parse_llm_adapter / parse_compute_adapter. Parse the named-adapter form `adapter :tts, name: :foo, provider: :elevenlabs, voice_id:, model:, speed:, stability:, similarity_boost:, style:, trigger_on:, cache_dir:, auto_play:` into a TtsAdapter. Returns None when `name:` is absent — the caller falls back to io_adapter routing for any bare `:tts` form (forwards-compat, mirrors parse_compute_adapter). `:tts` is fire-and-forget (`response_field :none`) so there is no response_into / attr pair.
fn parse_tts_adapter(rest: &str) -> Option<TtsAdapter> {
    let mut ta = TtsAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { ta.name = strip_symbol(&v); got_name = true; }
            "provider" => ta.provider = Some(strip_symbol(&v)),
            "voice_id" => ta.voice_id = Some(strip_quotes(&v)),
            "model" => ta.model = Some(strip_quotes(&v)),
            "speed" => ta.speed = Some(strip_quotes(&v)),
            "stability" => ta.stability = Some(strip_quotes(&v)),
            "similarity_boost" => ta.similarity_boost = Some(strip_quotes(&v)),
            "style" => ta.style = Some(strip_quotes(&v)),
            "trigger_on" => ta.trigger_on = Some(strip_quotes(&v)),
            "cache_dir" => ta.cache_dir = Some(strip_quotes(&v)),
            "auto_play" => ta.auto_play = Some(strip_quotes(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(ta)
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
            //     voice_id   "WwS1lF7yiubZWoroH5D5"   # Björk-tone
            // emitted `voice_id: "WwS1lF7yiubZWoroH5D5" # ...` and
            // strip_quotes (matches both ends) left the literal quotes
            // intact, which broke downstream URL construction in the
            // :tts dispatcher and any other consumer that expected a
            // clean value. Inlined here (not pulled into its own helper)
            // so the specializer golden (codegen/hecksagon_parser_shape/
            // snippets/join_adapter_lines_body.rs.frag) stays a single
            // self-contained snippet — no new ParserHelper fixture row
            // needed.
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
        i += 1;
    }
    (Some(adapter), i)
}

/// Parse one `driven on "Event" do |e| dispatch "X.Y", k: v ... end`
/// block. Returns (Some(DrivenHandler), lines_consumed).
fn parse_driven_handler(lines: &[&str]) -> (Option<DrivenHandler>, usize) {
    let first = lines[0].trim();
    let event_ref = match between_quotes(first) { Some(e) => e, None => return (None, 1) };
    let mut handler = DrivenHandler { event_ref, dispatches: Vec::new() };
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
    let attrs = match split_at {
        Some(idx) => parse_options(body[idx + 1..].trim_end_matches(')').trim()),
        None => Vec::new(),
    };
    Some(DrivenDispatch { command, attrs })
}
