/// Build the attrs map for a runtime dispatch from the test DSL's
/// reference-only world. Two layers:
///
/// 1. Convert the user-typed kwargs (domain attrs only — no ids).
/// 2. For every reference declared on the command, inject the in-scope
///    id automatically. The user never types an id; the runner looks
///    up "the most recently created Pizza" from in_scope and provides
///    the runtime its internal id. This is the bluebook→repository
///    translation: above, references; below, ids.
///
/// If a reference can't be resolved (no in-scope aggregate of that
/// type), the kwarg is omitted — the runtime will then either error
/// (loud, useful failure pointing at missing setup) or singleton-create
/// for is_create commands.
fn build_attrs(
    args: &BTreeMap<String, String>,
    command_name: &str,
    rt: &Runtime,
    in_scope: &HashMap<String, String>,
) -> HashMap<String, Value> {
    let mut attrs = to_runtime_attrs(args);
    if let Some(cmd) = find_command(rt, command_name) {
        for r in &cmd.references {
            // Don't overwrite if the user explicitly set this kwarg
            // (escape hatch for advanced cases — tests usually don't).
            if attrs.contains_key(&r.name) { continue; }
            if let Some(id) = in_scope.get(&r.target) {
                attrs.insert(r.name.clone(), Value::Str(id.clone()));
            }
        }
    }
    attrs
}

