    // Find the first top-level comma after the aggregate's name —
    // that separates `aggregate "X"` from its kwargs. Top-level
    // matters because a future bluebook form could theoretically
    // embed commas in `"strings"` inside the name slot; current
    // names are PascalCase but we keep the code honest.
    let comma_pos = first_top_level_comma(line)?;
    let after_comma = &line[comma_pos + 1..];
    let schema_pos = after_comma.find("schema:")?;
    let after_schema = &after_comma[schema_pos + "schema:".len()..];

    // Find the opening `{` after `schema:` and its balanced `}`.
    let open = after_schema.find('{')?;
    let close = matching_close_brace(after_schema, open)?;
    let body = &after_schema[open + 1..close];

    let mut attrs = Vec::new();
    for part in split_top_level_commas(body) {
        let part = part.trim();
        if part.is_empty() { continue; }
        // Each pair is `name: Type`. We split on the first top-level
        // colon so the type token (which never legitimately contains
        // a `:`) is preserved intact even if future types do.
        let colon = part.find(':')?;
        let name = part[..colon].trim().to_string();
        let type_name = part[colon + 1..].trim().to_string();
        if name.is_empty() || type_name.is_empty() { return None; }
        attrs.push(CatalogAttr { name, type_name });
    }
    Some(attrs)
