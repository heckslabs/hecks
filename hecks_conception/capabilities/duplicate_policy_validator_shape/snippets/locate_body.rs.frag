    match &p.target_domain {
        Some(d) if !d.is_empty() => format!("{}@{}", p.name, d),
        _                        => p.name.clone(),
    }
