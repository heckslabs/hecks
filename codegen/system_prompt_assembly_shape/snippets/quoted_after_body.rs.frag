// Snippet: body of `quoted_after` — substring between the first marker
// (ending at an opening quote) and the next quote.
    let start = src.find(marker)? + marker.len();
    let rest = &src[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
