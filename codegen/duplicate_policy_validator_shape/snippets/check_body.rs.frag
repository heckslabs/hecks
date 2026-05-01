    let mut by_key: BTreeMap<(String, String), Vec<&Policy>> = BTreeMap::new();
    for p in &domain.policies {
        let key = (p.on_event.clone(), p.trigger_command.clone());
        by_key.entry(key).or_default().push(p);
    }

    let mut findings = Vec::new();
    for ((event, trigger), group) in &by_key {
        if group.len() < 2 { continue; }
        let names: Vec<String> = group.iter().map(|p| locate(p)).collect();
        let location = names.join(", ");
        findings.push(Finding::err(
            location,
            format!(
                "{} policies share (on: {:?}, trigger: {:?}) — the \
                 trigger fires once per matching policy, so {} will \
                 run {} times per {} event. Delete the duplicates or \
                 collapse them into one policy.",
                group.len(), event, trigger, trigger, group.len(), event,
            ),
        ));
    }
    Report { findings }
