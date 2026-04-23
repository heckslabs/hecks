    let v: Vec<String> = set.iter().map(|s| format!("{:?}", s)).collect();
    if v.is_empty() { "{}".into() } else { format!("{{{}}}", v.join(", ")) }
