pub fn parse_attribute(line: &str) -> Option<Attribute> {
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();

    // Two declaration shapes resolve to the same Attribute IR :
    //
    //   1. Primitive / explicit-name form
    //        attribute :role, String
    //        attribute :role, String, default: "owner"
    //      The first part carries `:name`; extract_symbol picks it up
    //      and parts[1] (if present) is the positional type.
    //
    //   2. i255 bare-VO form (PascalCase value-object as the type-and-
    //      identity)
    //        attribute Role                 → name = "role" (snake_case VO)
    //        attribute Role, as: :role      → name = "role" (explicit alias)
    //      Here the first part has no leading `:` ; the VO name is the
    //      type, and the alias either falls out of `as: :alias` in
    //      parts[1] or defaults to to_snake_case(VO).
    //
    // i479 — without the bare-VO branch, the parser silently drops
    // every `attribute Role, as: :role` line, so any `then_set :role`
    // referencing it tripped check-lifecycle's mutation-reference
    // gate as if the attribute didn't exist.
    let (name, attr_type) = if let Some(sym) = extract_symbol(first) {
        (sym, None)
    } else {
        let vo_name = bare_vo_type(first)?;
        let alias = parts.get(1)
            .and_then(|p| p.find("as:").map(|pos| &p[pos + "as:".len()..]))
            .and_then(extract_symbol)
            .unwrap_or_else(|| to_snake_case(&vo_name));
        (alias, Some(vo_name))
    };

    // Resolve the type from parts[1]. Three cases:
    //   - `list_of(X)`     → extract X, set list=true
    //   - `default: ...`   (or any kwarg) → no positional type, default to "String"
    //   - bare token       → use it as the type (String, Integer, MyValueObject, …)
    let raw = parts.get(1).map(|s| s.trim()).unwrap_or("");
    // Retired 2026-05-12 : Array / Hash bare-types USED to auto-flag
    // list=true (mirroring an old Ruby heuristic). Both heuristics
    // retired together so the parsers agree : collection shape MUST
    // come from `list_of(X)` explicitly. Bluebooks that used bare
    // Array / Hash and meant "scalar collection-shaped attr" stay
    // scalar ; if they meant a list, they now must say `list_of(...)`.
    // `:list_ofs` (substring of "list_of") must NOT register — only
    // `list_of(` with the paren counts.
    let list = line.contains("list_of(");
    let attr_type = if let Some(t) = attr_type {
        // Bare-VO form already pinned the type to the value-object name.
        t
    } else if raw.starts_with("list_of(") {
        let open = raw.find('(')? + 1;
        let close = raw.find(')')?;
        raw[open..close].trim().to_string()
    } else if raw.is_empty() || is_kwarg(raw) {
        "String".to_string()
    } else {
        raw.to_string()
    };

    let default = if line.contains("default:") {
        let after = extract_after(line, "default:")?;
        if after.contains('"') { extract_string(&after) }
        else { Some(after.split_whitespace().next().unwrap_or(&after).to_string()) }
    } else { None };
    Some(Attribute { name, attr_type, default, list })
}

/// Pull the PascalCase value-object name from the first segment of a
/// bare-VO `attribute Role` / `attribute Role, as: :alias` line.
/// Returns None for primitive forms (which extract_symbol handles)
/// and for leading tokens that aren't PascalCase.
fn bare_vo_type(first: &str) -> Option<String> {
    let after_kw = first.strip_prefix("attribute")?.trim_start();
    let token: String = after_kw.chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if token.is_empty() { return None; }
    let mut chars = token.chars();
    let head = chars.next()?;
    if !head.is_uppercase() { return None; }
    Some(token)
}

