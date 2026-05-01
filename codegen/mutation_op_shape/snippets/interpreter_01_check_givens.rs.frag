pub fn check_givens(
    cmd: &Command,
    state: &AggregateState,
    attrs: &HashMap<String, Value>,
) -> Result<(), RuntimeError> {
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

