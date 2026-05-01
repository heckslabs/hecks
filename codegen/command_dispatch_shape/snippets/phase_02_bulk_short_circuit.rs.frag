    // Many-form dispatch (i113 / i116) — only applies to aggregate-level
    // commands. Entity commands route through the parent's record and
    // don't currently support the list_of(VO) bulk pattern.
    if let Resolution::Aggregate(_, cmd_idx) = res {
        if let Some(spec_attr) = bulk_spec_attr(rt, agg_idx, cmd_idx) {
            return dispatch_bulk(rt, agg_idx, cmd_idx, command_name, &spec_attr, attrs);
        }
    }
