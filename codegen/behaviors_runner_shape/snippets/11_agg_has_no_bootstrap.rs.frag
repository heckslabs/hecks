/// True when every command on the aggregate references its own type
/// (no command can act as a fresh-instance bootstrap from the bluebook).
fn agg_has_no_bootstrap(agg: &crate::ir::Aggregate) -> bool {
    if agg.commands.is_empty() { return false; }
    let agg_snake = to_snake(&agg.name);
    agg.commands.iter().all(|cmd| {
        cmd.references.iter().any(|r| {
            let target_snake = to_snake(&r.target);
            target_snake == agg_snake || agg_snake.ends_with(&target_snake)
        })
    })
}

