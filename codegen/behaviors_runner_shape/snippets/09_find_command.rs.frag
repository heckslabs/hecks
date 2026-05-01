fn find_command<'a>(rt: &'a Runtime, name: &str) -> Option<&'a crate::ir::Command> {
    // i156 — accept the same three address forms as `command_dispatch::resolve` :
    // Context.Aggregate.Command, Aggregate.Command, and bare Command. Bare-name
    // setups historically picked first-match-wins ; qualified setups (i142+)
    // must filter by aggregate (and optionally context) so reference injection
    // looks up self-ref kwargs against the right aggregate.
    let parts: Vec<&str> = name.split('.').collect();
    match parts.as_slice() {
        [context, agg_name, cmd_name] => {
            for agg in &rt.domain.aggregates {
                if agg.name != *agg_name { continue; }
                if agg.context.as_deref() != Some(*context) { continue; }
                if let Some(c) = agg.commands.iter().find(|c| c.name == *cmd_name) {
                    return Some(c);
                }
            }
            None
        }
        [agg_name, cmd_name] => {
            for agg in &rt.domain.aggregates {
                if agg.name != *agg_name { continue; }
                if let Some(c) = agg.commands.iter().find(|c| c.name == *cmd_name) {
                    return Some(c);
                }
            }
            None
        }
        _ => {
            for agg in &rt.domain.aggregates {
                if let Some(c) = agg.commands.iter().find(|c| c.name == name) {
                    return Some(c);
                }
            }
            None
        }
    }
}

