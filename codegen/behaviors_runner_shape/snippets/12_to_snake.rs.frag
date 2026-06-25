fn to_snake(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { out.push('_'); }
        out.push(c.to_lowercase().next().unwrap_or(c));
    }
    out
}

