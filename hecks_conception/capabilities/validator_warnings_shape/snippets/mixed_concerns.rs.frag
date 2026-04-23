// Snippet: mixed_concerns body — sui-generis BFS logic that doesn't
// fit a check_kind primitive. Referenced by the `MixedConcernsWarning`
// fixture's snippet_path. The specializer interpolates this directly
// as the function body between the opening `{` and closing `}`.
//
// Tracked for taxonomy lift-out in inbox i58 (graph_components as IR).
    if domain.aggregates.len() < 5 {
        return None;
    }

    let names: Vec<&str> = domain.aggregates.iter().map(|a| a.name.as_str()).collect();
    let name_set: HashSet<&str> = names.iter().copied().collect();

    // adjacency: aggregate name -> set of neighbor names
    let mut adj: HashMap<&str, HashSet<&str>> = HashMap::new();
    for name in &names {
        adj.insert(name, HashSet::new());
    }

    // Edges from reference_to on aggregate attributes (Reference)
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if reference.domain.is_none() && name_set.contains(reference.target.as_str()) {
                let a = agg.name.as_str();
                let b = reference.target.as_str();
                if a != b {
                    adj.get_mut(a).map(|s| s.insert(b));
                    adj.get_mut(b).map(|s| s.insert(a));
                }
            }
        }
        // Edges from reference_to on command parameters
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if reference.domain.is_none() && name_set.contains(reference.target.as_str()) {
                    let a = agg.name.as_str();
                    let b = reference.target.as_str();
                    if a != b {
                        adj.get_mut(a).map(|s| s.insert(b));
                        adj.get_mut(b).map(|s| s.insert(a));
                    }
                }
            }
        }
    }

    // Build event->aggregate and command->aggregate maps for policy edges
    let mut event_to_agg: HashMap<&str, &str> = HashMap::new();
    let mut cmd_to_agg: HashMap<&str, &str> = HashMap::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            cmd_to_agg.insert(cmd.name.as_str(), agg.name.as_str());
            if let Some(ref event) = cmd.emits {
                event_to_agg.insert(event.as_str(), agg.name.as_str());
            }
        }
    }
    // Edges from within-domain policies (a policy on A triggers a command on B)
    for policy in &domain.policies {
        if policy.target_domain.is_some() {
            continue;
        }
        let from = event_to_agg.get(policy.on_event.as_str());
        let to = cmd_to_agg.get(policy.trigger_command.as_str());
        if let (Some(&f), Some(&t)) = (from, to) {
            if f != t {
                adj.get_mut(f).map(|s| s.insert(t));
                adj.get_mut(t).map(|s| s.insert(f));
            }
        }
    }

    // BFS to find connected components
    let mut visited: HashSet<&str> = HashSet::new();
    let mut components: Vec<Vec<&str>> = vec![];
    for name in &names {
        if visited.contains(name) {
            continue;
        }
        let mut component = vec![];
        let mut queue = VecDeque::new();
        queue.push_back(*name);
        visited.insert(name);
        while let Some(current) = queue.pop_front() {
            component.push(current);
            if let Some(neighbors) = adj.get(current) {
                for &neighbor in neighbors {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor);
                        queue.push_back(neighbor);
                    }
                }
            }
        }
        components.push(component);
    }

    if components.len() <= 1 {
        return None;
    }

    let rendered: Vec<String> = components
        .iter()
        .map(|c| format!("[{}]", c.join(",")))
        .collect();

    Some(format!(
        "⚠ domain '{}' has {} disconnected concern clusters: {}",
        domain.name,
        components.len(),
        rendered.join(" and ")
    ))
