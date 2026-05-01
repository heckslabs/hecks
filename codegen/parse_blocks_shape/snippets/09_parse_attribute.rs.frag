pub fn parse_attribute(line: &str) -> Option<Attribute> {
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();
    let name = extract_symbol(first)?;

    // Resolve the type from parts[1]. Three cases:
    //   - `list_of(X)`     → extract X, set list=true
    //   - `default: ...`   (or any kwarg) → no positional type, default to "String"
    //   - bare token       → use it as the type (String, Integer, MyValueObject, …)
    let raw = parts.get(1).map(|s| s.trim()).unwrap_or("");
    // `list_of(X)` is the explicit collection form. `Array` and `Hash`
    // as bare types are also collection-shaped (Ruby DSL treats them
    // as list:true). `:list_ofs` (substring of "list_of") must NOT
    // register — only `list_of(` with the paren counts.
    let list = line.contains("list_of(") || raw == "Array" || raw == "Hash";
    let attr_type = if raw.starts_with("list_of(") {
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

