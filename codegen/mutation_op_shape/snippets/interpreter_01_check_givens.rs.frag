pub fn check_givens(
    cmd: &Command,
    state: &AggregateState,
    attrs: &HashMap<String, Value>,
) -> Result<(), RuntimeError> {
    // `required: true` attributes are enforced before givens — a kwarg that is
    // absent, Null, or empty refuses the command the same shape a failed given
    // does. Structural superset of the old `given { x != "" }` idiom, which
    // could not see a truly-absent (Null) kwarg.
    for attr in &cmd.attributes {
        if attr.required {
            let present = attrs.get(&attr.name)
                .map_or(false, |v| !matches!(v, Value::Null) && v.to_string() != "");
            if !present {
                return Err(RuntimeError::GivenFailed {
                    message: format!("{} is required", attr.name),
                    expression: "required".to_string(),
                });
            }
        }
    }
    for given in &cmd.givens {
        if !evaluate_given(&given.expression, state, attrs) {
            return Err(RuntimeError::GivenFailed {
                message: given
                    .message
                    .clone()
                    .unwrap_or_else(|| given.expression.clone()),
                expression: given.expression.clone(),
            });
        }
    }
    Ok(())
}

