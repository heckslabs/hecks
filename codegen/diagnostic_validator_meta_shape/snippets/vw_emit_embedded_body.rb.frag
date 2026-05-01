        a = rule["attrs"]
        path = REPO_ROOT.join(a["snippet_path"])
        body = read_snippet_body(path)
        threshold = a["threshold"].to_i
        doc = [
          "Returns Some(msg) if the domain has #{threshold}+ aggregates split across",
          "disconnected reference/policy clusters.",
        ]
        <<~RS
          /// #{doc[0]}
          /// #{doc[1]}
          pub fn #{a["rust_fn_name"]}(domain: &Domain) -> Option<String> {
          #{body}}
        RS
