    // create-vs-update is now a persistence upsert keyed on identity (see
    // the resolution block below) — the #729 name-heuristic and the
    // first-class-factory `is_create` bit both retired. `self_ref` survives
    // only to resolve the id a legacy `reference_to` kwarg carries.
    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    // ROOT-3 — singleton identity from the declared default. A singleton declares
    // `identified_by :name` + `attribute :name, default: "X"`. id_for_command keys
    // off `attrs`, but the attribute default was only applied to STATE (AFTER id
    // resolution), so a policy/PM dispatch that omitted the key counter-minted a
    // new row instead of keying the singleton (statusline 3881 rows, awareness "1",
    // the Seed gather). Inject the identity attribute's declared default into attrs
    // BEFORE id resolution, so a singleton keys by its name whether or not the
    // caller passed it. Command default wins ; else the aggregate's. No-op when the
    // key is already supplied or carries no default (non-singleton aggregates).
    let mut attrs = attrs;
    if let Some(key) = rt.domain.aggregates[agg_idx].identified_by.clone() {
        if !attrs.contains_key(&key) {
            let cmd = cmd_for(rt, res);
            let from_cmd = cmd.attributes.iter().find(|a| a.name == key);
            let from_agg = rt.domain.aggregates[agg_idx].attributes.iter().find(|a| a.name == key);
            if let Some(d) = from_cmd.and_then(|a| a.default.clone())
                .or_else(|| from_agg.and_then(|a| a.default.clone()))
            {
                let attr_type = from_cmd.map(|a| a.attr_type.clone())
                    .or_else(|| from_agg.map(|a| a.attr_type.clone()))
                    .unwrap_or_default();
                attrs.insert(key.clone(), parse_default(&d, &attr_type));
            }
        }
    }
    let attrs = attrs;
