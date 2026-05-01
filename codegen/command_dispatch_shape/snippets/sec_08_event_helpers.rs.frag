/// Resolution-aware event builder (i111-J). Entity commands emit
/// events tagged with the parent aggregate's name — that's the
/// addressable record from outside the bounded context — but use
/// the entity command's `emits:` declaration when present.
fn build_event_res(
    rt: &Runtime, res: Resolution,
    aggregate_id: &str, attrs: &HashMap<String, Value>,
) -> Option<Event> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let event_name = cmd.emits.clone().unwrap_or_else(|| default_event_name(&cmd.name));
    Some(Event {
        name: event_name,
        aggregate_type: agg.name.clone(),
        aggregate_id: aggregate_id.to_string(),
        data: attrs.clone(),
    })
}

fn default_event_name(cmd_name: &str) -> String {
    if let Some(rest) = cmd_name.strip_prefix("Create") {
        format!("{}Created", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Add") {
        format!("{}Added", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Place") {
        format!("{}Placed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Cancel") {
        format!("{}Cancelled", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Update") {
        format!("{}Updated", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Remove") {
        format!("{}Removed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Delete") {
        format!("{}Deleted", rest)
    } else {
        format!("{}Completed", cmd_name)
    }
}

fn parse_default(default: &str, attr_type: &str) -> Value {
    match attr_type {
        "Integer" => Value::Int(default.parse().unwrap_or(0)),
        "Boolean" => Value::Bool(default == "true"),
        _ => Value::Str(default.trim_matches('"').to_string()),
    }
}

fn to_snake_case(s: &str) -> String {
    crate::parser_helpers::to_snake_case(s)
}

