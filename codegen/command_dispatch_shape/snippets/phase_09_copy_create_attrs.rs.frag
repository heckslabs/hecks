    // Create commands copy matching attrs to aggregate. For entity
    // commands the parent aggregate's attribute set is the target
    // schema (entities live within the parent's record). This phase runs
    // BEFORE pipeline_core (givens -> mutations -> invariants), so a
    // pure-data create like EventSourcing::Event.Append populates its VO
    // attrs here and check_invariants enforces on the REAL values, not
    // the apply_defaults empty-list placeholders. then_set mutations run
    // after and override on overlap (no corpus then_set targets a raw
    // create-attr name, so this is inert for existing aggregates).
    if is_new {
        let agg_attr_names: Vec<&str> = rt.domain.aggregates[agg_idx]
            .attributes.iter().map(|a| a.name.as_str()).collect();
        let cmd = cmd_for(rt, res);
        for cmd_attr in &cmd.attributes {
            if agg_attr_names.contains(&cmd_attr.name.as_str()) {
                if let Some(val) = attrs.get(&cmd_attr.name) {
                    state.set(&cmd_attr.name, val.clone());
                }
            }
        }
    }
