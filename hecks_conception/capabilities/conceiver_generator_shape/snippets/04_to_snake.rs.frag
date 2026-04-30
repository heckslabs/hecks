fn to_snake(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { result.push('_'); }
        if c.is_whitespace() { result.push('_'); }
        else { result.push(c.to_lowercase().next().unwrap()); }
    }
    result
}
