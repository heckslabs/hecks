// Snippet: body of `assemble_sections` — parse the content fixtures and
// concatenate SystemPromptSection markdown bodies in numeric :order.
    let parsed = crate::fixtures_parser::parse(source);
    let mut sections: Vec<(i64, String)> = parsed
        .fixtures
        .iter()
        .filter(|f| f.aggregate_name == "SystemPromptSection")
        .map(|f| {
            let order = f
                .attributes
                .iter()
                .find(|(k, _)| k == "order")
                .and_then(|(_, v)| v.trim().parse::<i64>().ok())
                .unwrap_or(i64::MAX);
            let markdown = f
                .attributes
                .iter()
                .find(|(k, _)| k == "markdown")
                .map(|(_, v)| v.clone())
                .unwrap_or_default();
            (order, markdown)
        })
        .collect();
    sections.sort_by_key(|(order, _)| *order);
    sections
        .iter()
        .map(|(_, md)| md.as_str())
        .collect::<Vec<_>>()
        .join("\n")
