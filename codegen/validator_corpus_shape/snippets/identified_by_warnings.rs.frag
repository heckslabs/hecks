/// Flags aggregates that have a `lifecycle` block OR a self-referencing
/// `reference_to` (a command pointing back to its own aggregate) but
/// declare no `identified_by`. Without `identified_by`, the in-memory
/// runner counter-mints a fresh u64 id on every dispatch — the lifecycle
/// state never advances past `pending`, and the self-ref form (used by
/// transition commands) targets a fresh record each time.
///
/// Skipped when the aggregate has `identified_by` already, or when it
/// has neither a lifecycle nor a self-ref (event-log style stores
/// legitimately want counter-mint behavior).
///
/// Per-bluebook check — no corpus context required. Returns one warning
/// per offending aggregate.
pub fn identified_by_warnings(domain: &Domain) -> Vec<String> {
    let mut warnings = vec![];
    for agg in &domain.aggregates {
        if agg.identified_by.is_some() {
            continue;
        }
        let has_lifecycle = agg.lifecycle.is_some();
        let has_self_ref = agg.commands.iter().any(|cmd| {
            cmd.references.iter().any(|r| r.target == agg.name && r.domain.is_none())
        });
        if !has_lifecycle && !has_self_ref {
            continue;
        }
        warnings.push(format!(
            "⚠ aggregate '{}' has a {} but no identified_by — consider 'identified_by :name' so the in-memory runner converges on a single record",
            agg.name,
            if has_lifecycle { "lifecycle" } else { "self-referencing command" }
        ));
    }
    warnings
}
