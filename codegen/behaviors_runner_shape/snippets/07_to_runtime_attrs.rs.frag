/// Convert behaviors-IR string args (the source-token form) into the
/// dynamic Value type the runtime dispatch loop expects. Numbers stay
/// numbers; quoted strings come through unwrapped (already).
fn to_runtime_attrs(args: &BTreeMap<String, String>) -> HashMap<String, Value> {
    args.iter()
        .map(|(k, v)| (k.clone(), parse_value(v)))
        .collect()
}

