pub fn dispatch(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, None)
}

/// Cascade-aware dispatch (i111-K) — used by `Runtime::drain_policies`
/// when the triggered command's aggregate has the SAME type as the
/// upstream event. Passing the upstream id as a hint lets the second
/// dispatch reuse the existing record instead of counter-minting a
/// fresh id.
///
/// This closes the i111-C surprise : multi-step pipelines like
/// CorpusPruning (Measure → Split with `given { measured == true }`)
/// previously needed `identified_by` declared just to keep the cascade
/// landing on the same row. With this hint, the cascade preserves the
/// id automatically — `identified_by` becomes a query / addressability
/// concern, not a cascade-correctness requirement.
///
/// The hint is honored only when :
///   - The triggered command's aggregate type matches `upstream_type`
///   - A record already exists at `upstream_id` in that repo
/// Otherwise the dispatch falls through to standard id resolution
/// (identified_by lookup → counter-mint), keeping cross-type cascades
/// and missing-record cases unchanged.
pub fn dispatch_cascade(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
    upstream_type: &str,
    upstream_id: &str,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, Some((upstream_type.to_string(), upstream_id.to_string())))
}

