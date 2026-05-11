
    if command == "dump-fixtures" {
        let path = args.get(2).expect("usage: storehouse dump-fixtures <file.fixtures>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let file = storehouse::fixtures_parser::parse(&source);
        let mut payload = serde_json::json!({
            "domain": file.domain_name,
            "fixtures": file.fixtures.iter().map(|f| {
                let mut attrs = serde_json::Map::new();
                for (k, v) in &f.attributes {
                    attrs.insert(k.clone(), serde_json::Value::String(v.clone()));
                }
                serde_json::json!({
                    "aggregate": f.aggregate_name,
                    "name": f.name.clone().unwrap_or_default(),
                    "attrs": attrs,
                })
            }).collect::<Vec<_>>(),
        });
        // i42: emit a `catalogs` key only when the file actually
        // declares catalog schemas. Absent-key preserves the pre-i42
        // payload shape for the ~356 existing .fixtures files, so
        // downstream consumers that don't care about catalogs see
        // exactly the same JSON they saw before.
        if !file.catalogs.is_empty() {
            let mut catalogs = serde_json::Map::new();
            for (agg, attrs) in &file.catalogs {
                let rows: Vec<serde_json::Value> = attrs.iter().map(|a| {
                    serde_json::json!({ "name": a.name, "type": a.type_name })
                }).collect();
                catalogs.insert(agg.clone(), serde_json::Value::Array(rows));
            }
            payload.as_object_mut().unwrap()
                .insert("catalogs".into(), serde_json::Value::Object(catalogs));
        }
        println!("{}", serde_json::to_string_pretty(&payload).unwrap());
        return;
    }
