    // Per i563/i568 — when a `lifecycle :foo` block tracks an attribute,
    // AND that attribute is wrapped as a VO (per no_primitive_envy), the
    // attribute MUST carry an explicit `default:` clause matching the
    // lifecycle's initial state. Otherwise the dispatcher reads the
    // wrapped VO back as `"[0 items]"` and the lifecycle's `from:`
    // clauses fail to match the stringified initial state.
    //
    // Primitive-typed lifecycle attrs (String/Integer/etc) are OK without
    // a default — the runtime gives them a sensible empty value the
    // lifecycle's `from:` clauses can still match against. The bug only
    // bites the VO-wrapped form.
    let Some(lc) = &agg.lifecycle else { return };

    // Locate the lifecycle-tracked attribute on the aggregate.
    let Some(attr) = agg.attributes.iter().find(|a| a.name == lc.field) else { return };

    // Is the attribute's declared type a value-object declared on the
    // same aggregate? That's the VO-wrap signal.
    let is_vo = agg.value_objects.iter().any(|vo| vo.name == attr.attr_type);
    if !is_vo { return; }

    // Wrapped lifecycle attrs MUST carry `default:` — otherwise the
    // wrapped VO deserializes as "[0 items]" and the lifecycle's
    // `from:` clauses fail at the first transition.
    if attr.default.is_none() {
        out.push(Finding::err(
            format!("{}.{}", agg.name, attr.name),
            format!(
                "lifecycle-tracked attribute :{} on aggregate '{}' is \
                 wrapped as VO '{}' but missing default: clause — \
                 wrapped lifecycle attrs deserialize as '[0 items]' \
                 without an explicit default matching the lifecycle's \
                 initial state (lifecycle default: {:?})",
                attr.name, agg.name, attr.attr_type, lc.default,
            ),
        ));
    }
