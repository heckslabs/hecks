use crate::hecksagon_helpers::*;
use crate::hecksagon_ir::*;

pub fn is_hecksagon_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
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
            if let Some(n) = between_quotes(line) {
                hex.name = n;
            }
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.adapter_family") {
            if let Some(n) = between_quotes(line) {
                hex.name = n;
            }
            hex.framework_kind = Some("adapter_family".to_string());
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.provider") {
            if let Some(n) = between_quotes(line) {
                hex.name = n;
            }
            hex.framework_kind = Some("provider".to_string());
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.behavior_kind") {
            if let Some(n) = between_quotes(line) {
                hex.name = n;
            }
            hex.framework_kind = Some("behavior_kind".to_string());
            i += 1;
            continue;
        }

        if line.starts_with("subscribe") {
            if let Some(n) = between_quotes(line) {
                hex.subscriptions.push(n);
            }
            i += 1;
            continue;
        }

        if line.starts_with("gate ") {
            let (gate, consumed) = parse_gate(&raw[i..]);
            if let Some(g) = gate {
                hex.gates.push(g);
            }
            i += consumed;
            continue;
        }

        if line.starts_with("adapter \"") {
            let (driven, consumed_driven) = parse_driven_adapter(&raw[i..]);
            let (driving, _consumed_driving) = parse_driving_adapter(&raw[i..]);
            if let Some(d) = driven {
                if !d.handlers.is_empty() {
                    hex.driven_adapters.push(d);
                }
            }
            if let Some(d) = driving {
                if !d.handlers.is_empty() {
                    hex.driving_adapters.push(d);
                }
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
            if let Some(g) = gate {
                hex.families.push(g);
            }
            i += consumed;
            continue;
        }

        if line.starts_with("Hecks.adapter \"") {
            let (gate, consumed) = parse_adapter_decl(&raw[i..]);
            if let Some(g) = gate {
                hex.adapters.push(g);
            }
            i += consumed;
            continue;
        }

        if is_binding_line(line) {
            let (gate, consumed) = parse_binding(&raw[i..]);
            if let Some(g) = gate {
                hex.bindings.push(g);
            }
            i += consumed;
            continue;
        }

        i += 1;
    }

    hex
}

fn absorb_adapter(joined: &str, hex: &mut Hecksagon) {
    let body = joined
        .trim()
        .strip_prefix("adapter")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let (kind, rest) = split_first_symbol(body);
    if kind.is_empty() {
        return;
    }
    match kind.as_str() {
        "shell" => {
            if let Some(sa) = parse_shell_adapter(rest) {
                hex.shell_adapters.push(sa);
            }
        }
        "llm" => {
            if let Some(la) = parse_llm_adapter(rest) {
                hex.llm_adapters.push(la);
            } else {
                let mut io = IoAdapter {
                    kind,
                    options: parse_options(rest),
                    on_events: vec![],
                };
                for ev in extract_on_events(rest) {
                    io.on_events.push(ev);
                }
                hex.io_adapters.push(io);
            }
        }
        "compute" => {
            if let Some(ca) = parse_compute_adapter(rest) {
                hex.compute_adapters.push(ca);
            } else {
                let mut io = IoAdapter {
                    kind,
                    options: parse_options(rest),
                    on_events: vec![],
                };
                for ev in extract_on_events(rest) {
                    io.on_events.push(ev);
                }
                hex.io_adapters.push(io);
            }
        }
        "memory" | "heki" => {
            hex.persistence = Some(kind);
        }
        "sqlite" | "postgres" | "mysql" => {
            hex.persistence = Some(kind);
            hex.persistence_options = parse_options(rest);
        }
        _ => {
            let mut io = IoAdapter {
                kind,
                options: parse_options(rest),
                on_events: vec![],
            };
            for ev in extract_on_events(rest) {
                io.on_events.push(ev);
            }
            hex.io_adapters.push(io);
        }
    }
}

fn parse_llm_adapter(rest: &str) -> Option<LlmAdapter> {
    let mut la = LlmAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => {
                la.name = strip_symbol(&v);
                got_name = true;
            }
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
    if !got_name {
        return None;
    }
    Some(la)
}

fn parse_compute_adapter(rest: &str) -> Option<ComputeAdapter> {
    let mut ca = ComputeAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => {
                ca.name = strip_symbol(&v);
                got_name = true;
            }
            "function" => {
                let stripped = strip_quotes(&v);
                ca.function_name = if stripped == v {
                    strip_symbol(&v)
                } else {
                    stripped
                };
            }
            "trigger_on" => ca.trigger_on = Some(strip_quotes(&v)),
            "response_into" => ca.response_into_target = Some(strip_quotes(&v)),
            "attr" => ca.response_into_attr = Some(strip_symbol(&v)),
            _ => {}
        }
    }
    if !got_name {
        return None;
    }
    Some(ca)
}

fn parse_shell_adapter(rest: &str) -> Option<ShellAdapter> {
    let mut sa = ShellAdapter {
        output_format: "text".into(),
        ok_exit: 0,
        ..Default::default()
    };
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => {
                let stripped = strip_quotes(&v);
                sa.name = if stripped == v {
                    strip_symbol(&v)
                } else {
                    stripped
                };
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
    if sa.name.is_empty() || sa.command.is_empty() {
        return None;
    }
    if sa.args.is_empty() {
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

fn parse_gate(lines: &[&str]) -> (Option<Gate>, usize) {
    let first = lines[0].trim();
    let mut gate = Gate::default();
    if let Some(n) = between_quotes(first) {
        gate.aggregate = n;
    }
    if let Some(after) = first.split(',').nth(1) {
        gate.role = strip_symbol(after.trim().trim_end_matches(" do"));
    }
    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") {
        1
    } else {
        0
    };
    let mut in_allow = false;
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            in_allow = false;
            i += 1;
            continue;
        }
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
                if !name.is_empty() {
                    gate.allowed_commands.push(name);
                }
            }
            in_allow = body_str.trim_end().ends_with(',');
        }
        i += 1;
    }
    if gate.aggregate.is_empty() {
        (None, i)
    } else {
        (Some(gate), i)
    }
}

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
            if joined.is_empty() {
                continue;
            }
            continue;
        }
        if !joined.is_empty() {
            joined.push(' ');
        }
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
        if depth <= 0 && !ends_comma {
            break;
        }
    }
    if joined.trim_end().ends_with(" do") {
        joined = joined
            .trim_end()
            .trim_end_matches(" do")
            .trim_end()
            .to_string();
        while idx < lines.len() {
            let raw_t = lines[idx];
            consumed += 1;
            idx += 1;
            let cleaned: String = {
                let mut out = String::with_capacity(raw_t.len());
                let mut in_str = false;
                let mut prev = '\0';
                for c in raw_t.chars() {
                    match c {
                        '"' if prev != '\\' => {
                            in_str = !in_str;
                            out.push(c);
                        }
                        '#' if !in_str => break,
                        _ => out.push(c),
                    }
                    prev = c;
                }
                out
            };
            let t = cleaned.trim();
            if t.is_empty() || t.starts_with('#') {
                continue;
            }
            if t == "end" {
                break;
            }
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

fn parse_driven_adapter(lines: &[&str]) -> (Option<DrivenAdapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) {
        Some(n) => n,
        None => return (None, 1),
    };
    let mut adapter = DrivenAdapter {
        name,
        handlers: Vec::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(adapter), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if t.starts_with("driven on") {
            let (handler, consumed) = parse_driven_handler(&lines[i..]);
            if let Some(h) = handler {
                adapter.handlers.push(h);
            }
            i += consumed;
            continue;
        }
        if t.starts_with("driving on") {
            let (_, consumed) = parse_driving_handler(&lines[i..]);
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
}

fn parse_driving_adapter(lines: &[&str]) -> (Option<DrivingAdapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) {
        Some(n) => n,
        None => return (None, 1),
    };
    let mut adapter = DrivingAdapter {
        name,
        handlers: Vec::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(adapter), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if t.starts_with("driving on") {
            let (handler, consumed) = parse_driving_handler(&lines[i..]);
            if let Some(h) = handler {
                adapter.handlers.push(h);
            }
            i += consumed;
            continue;
        }
        if t.starts_with("driven on") {
            let (_, consumed) = parse_driven_handler(&lines[i..]);
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
}

fn parse_driving_handler(lines: &[&str]) -> (Option<DrivingHandler>, usize) {
    let first = lines[0].trim();
    let after = match first.strip_prefix("driving on") {
        Some(s) => s.trim(),
        None => return (None, 1),
    };
    let kind_end = after
        .find(|c: char| c.is_whitespace() || c == '"')
        .unwrap_or(after.len());
    let kind = after[..kind_end].trim().to_string();
    if kind.is_empty() {
        return (None, 1);
    }
    let arg = between_quotes(after).unwrap_or_default();
    let mut handler = DrivingHandler {
        kind,
        arg,
        dispatches: Vec::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(handler), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
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

fn parse_driven_handler(lines: &[&str]) -> (Option<DrivenHandler>, usize) {
    let first = lines[0].trim();
    let event_ref = match between_quotes(first) {
        Some(e) => e,
        None => return (None, 1),
    };
    let mut handler = DrivenHandler {
        event_ref,
        canned: None,
        dispatches: Vec::new(),
        runs: Vec::new(),
        checks: Vec::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(handler), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if t == "canned do" || t.starts_with("canned do ") || t.starts_with("canned do;") {
            let (canned, consumed) = parse_canned_block(&lines[i..]);
            if let Some(c) = canned {
                handler.canned = Some(c);
            }
            i += consumed;
            continue;
        }
        if t.starts_with("run ") {
            let extracted = t.find('"').and_then(|s0| {
                let mut out = String::new();
                let mut rest_idx = t.len();
                let mut closed = false;
                let mut it = t.char_indices().filter(|&(i, _)| i > s0).peekable();
                while let Some((idx, c)) = it.next() {
                    if c == '\\' {
                        if let Some(&(_, '"')) = it.peek() {
                            out.push('"');
                            it.next();
                            continue;
                        }
                        out.push('\\');
                        continue;
                    }
                    if c == '"' {
                        closed = true;
                        rest_idx = idx + c.len_utf8();
                        break;
                    }
                    out.push(c);
                }
                if closed {
                    Some((out, rest_idx))
                } else {
                    None
                }
            });
            if let Some((cmd, rest_idx)) = extracted {
                let rest = &t[rest_idx..];
                if let Some(ri) = rest.find("result_into:") {
                    match between_quotes(&rest[ri..]) {
                        Some(target) => handler.checks.push(CheckLeaf {
                            cmd,
                            result_into: target,
                        }),
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

fn join_dispatch_lines(lines: &[&str]) -> (String, usize) {
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    for raw in lines.iter() {
        let t = raw.trim();
        consumed += 1;
        if t.is_empty() || t.starts_with('#') {
            if joined.is_empty() {
                continue;
            }
            continue;
        }
        if !joined.is_empty() {
            joined.push(' ');
        }
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
        if depth <= 0 && !ends_comma {
            break;
        }
    }
    (joined, consumed)
}

fn parse_driven_dispatch(joined: &str) -> Option<DrivenDispatch> {
    let body = joined
        .trim()
        .strip_prefix("dispatch")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let command = between_quotes(body)?;
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    let mut split_at: Option<usize> = None;
    for (idx, c) in body.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '(' | '[' | '{' if !in_str => depth += 1,
            ')' | ']' | '}' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
                split_at = Some(idx);
                break;
            }
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

fn parse_canned_block(lines: &[&str]) -> (Option<CannedResponse>, usize) {
    let first = lines[0].trim();
    let mut canned = CannedResponse { values: Vec::new() };

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
            if p.is_empty() {
                continue;
            }
            if let Some(kv) = parse_canned_kv(p) {
                canned.values.push(kv);
            }
        }
        return (Some(canned), 1);
    }

    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(canned), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if let Some(kv) = parse_canned_kv(t) {
            canned.values.push(kv);
        }
        i += 1;
    }
    (Some(canned), i)
}

fn parse_canned_kv(line: &str) -> Option<(String, String)> {
    let t = line.trim().trim_end_matches(';');
    let ident_end = t.find(|c: char| !c.is_alphanumeric() && c != '_')?;
    if ident_end == 0 {
        return None;
    }
    let key = t[..ident_end].to_string();
    let rest = t[ident_end..].trim().trim_end_matches(';').trim();
    if rest.is_empty() {
        return None;
    }
    Some((key, rest.to_string()))
}

fn parse_family(lines: &[&str]) -> (Option<Family>, usize) {
    fn sym_after(line: &str, keyword: &str) -> String {
        let rest = match line.strip_prefix(keyword) {
            Some(r) => r.trim_start(),
            None => return String::new(),
        };
        let rest = rest.strip_prefix(':').unwrap_or(rest);
        let end = rest
            .find(|c: char| c.is_whitespace() || c == '#' || c == ',')
            .unwrap_or(rest.len());
        rest[..end].trim().to_string()
    }
    fn source_from_decl(line: &str) -> String {
        if let Some(idx) = line.find("from:") {
            let after = line[idx + "from:".len()..].trim_start();
            let after = after.strip_prefix(':').unwrap_or(after);
            let end = after
                .find(|c: char| c.is_whitespace() || c == '#' || c == ',')
                .unwrap_or(after.len());
            let s = after[..end].trim();
            if !s.is_empty() {
                return s.to_string();
            }
        }
        "direct".to_string()
    }
    let first = lines[0].trim();
    let name = match between_quotes(first) {
        Some(n) => n,
        None => return (None, 1),
    };
    let mut family = Family {
        name,
        verb: String::new(),
        signal: String::new(),
        fields: Vec::new(),
        produces: Vec::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(family), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        match t.split_whitespace().next().unwrap_or("") {
            "verb" => {
                if let Some(v) = between_quotes(t) {
                    family.verb = v;
                }
            }
            "signal" => {
                family.signal = sym_after(t, "signal");
            }
            "field" => {
                let name = sym_after(t, "field");
                if !name.is_empty() {
                    family.fields.push(FamilyField {
                        name,
                        source: source_from_decl(t),
                    });
                }
            }
            "secret" => {
                let name = sym_after(t, "secret");
                if !name.is_empty() {
                    family.fields.push(FamilyField {
                        name,
                        source: "secret".to_string(),
                    });
                }
            }
            "produces" => {
                let name = sym_after(t, "produces");
                if !name.is_empty() {
                    family.produces.push(name);
                }
            }
            _ => {}
        }
        i += 1;
    }
    (Some(family), i)
}

fn parse_adapter_decl(lines: &[&str]) -> (Option<Adapter>, usize) {
    let first = lines[0].trim();
    let name = match between_quotes(first) {
        Some(n) => n,
        None => return (None, 1),
    };
    let mut adapter = Adapter {
        name,
        family: String::new(),
        handler: String::new(),
    };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" {
            return (Some(adapter), i + 1);
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if t.split_whitespace().next() == Some("family") {
            if let Some(f) = between_quotes(t) {
                adapter.family = f;
            }
        }
        if t.split_whitespace().next() == Some("handler") {
            if let Some(h) = between_quotes(t) {
                adapter.handler = h;
            }
        }
        i += 1;
    }
    (Some(adapter), i)
}

fn is_binding_line(line: &str) -> bool {
    let t = line.trim();
    match t.find("::") {
        Some(idx) if idx > 0 => {
            let head = &t[..idx];
            head.starts_with(|c: char| c.is_ascii_uppercase())
                && head.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && t.contains('.')
        }
        _ => false,
    }
}

fn parse_binding(lines: &[&str]) -> (Option<Binding>, usize) {
    let t = lines[0].trim();
    let paren = match t.find('(') {
        Some(p) => p,
        None => {
            let dot = match t.rfind('.') {
                Some(d) => d,
                None => return (None, 1),
            };
            let aggregate = t[..dot].trim().to_string();
            let verb = t[dot + 1..].trim().to_string();
            if aggregate.is_empty() || verb.is_empty() {
                return (None, 1);
            }
            return (
                Some(Binding {
                    aggregate,
                    verb,
                    adapter: String::new(),
                    role: String::new(),
                    on: String::new(),
                    success: String::new(),
                    failure: String::new(),
                }),
                1,
            );
        }
    };
    let head = &t[..paren];
    let dot = match head.rfind('.') {
        Some(d) => d,
        None => return (None, 1),
    };
    let aggregate = head[..dot].trim().to_string();
    let verb = head[dot + 1..].trim().to_string();
    if aggregate.is_empty() || verb.is_empty() {
        return (None, 1);
    }
    let args = &t[paren + 1..];
    let adapter = between_quotes(args).unwrap_or_default();
    let role = match args.find("role:") {
        Some(idx) => args[idx + "role:".len()..]
            .trim_start()
            .trim_start_matches(':')
            .split(|c: char| c == ',' || c == ')' || c.is_whitespace())
            .next()
            .unwrap_or_default()
            .to_string(),
        None => String::new(),
    };
    let on = match args.find("on:") {
        Some(idx) => between_quotes(&args[idx..]).unwrap_or_default(),
        None => String::new(),
    };
    let mut success = String::new();
    let mut failure = String::new();
    let mut consumed = 1;
    if t.trim_end().ends_with("do") {
        let mut i = 1;
        while i < lines.len() {
            let b = lines[i].trim();
            i += 1;
            if b == "end" {
                break;
            }
            if let Some(rest) = b.strip_prefix("success") {
                if let Some(v) = between_quotes(rest) {
                    success = v;
                }
            } else if let Some(rest) = b.strip_prefix("failure") {
                if let Some(v) = between_quotes(rest) {
                    failure = v;
                }
            }
        }
        consumed = i;
    }
    (
        Some(Binding {
            aggregate,
            verb,
            adapter,
            role,
            on,
            success,
            failure,
        }),
        consumed,
    )
}
