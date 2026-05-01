// Snippet: parse_shell_adapter body. Kwarg table maps eight keys
// (name:, command:, args:, output_format:, timeout:, working_dir:,
// env:, ok_exit:) to distinct conversion calls. Emitted verbatim;
// every arm is sui-generis.
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
