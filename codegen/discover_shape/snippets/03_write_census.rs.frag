/// Upsert the discovered counts into `<info_dir>/census.heki`. Mirrors
/// the shell's `storehouse heki upsert census.heki id=1 ...` line.
pub fn write_census(info_dir: &str, counts: &OrganCounts) -> Result<(), String> {
    let path = heki::path_for_lookup(info_dir.trim_end_matches("/"), "census");
    let mut rec = heki::Record::new();
    rec.insert("id".into(),                  serde_json::Value::String("1".into()));
    rec.insert("total_domains".into(),       n(counts.organs));
    rec.insert("total_aggregates".into(),    n(counts.aggregates));
    rec.insert("total_capabilities".into(),  n(counts.capabilities));
    rec.insert("total_nerves".into(),        n(counts.nerves));
    rec.insert("total_vows".into(),          n(counts.vows));
    let _ = heki::upsert(&path, &rec, heki::WriteContext::OutOfBand {
        reason: "boot-time census write — counts organs/aggregates/capabilities/nerves/vows from filesystem walk; not yet a dispatched command",
    })?;
    Ok(())
}

fn n(v: usize) -> serde_json::Value {
    serde_json::Value::Number(serde_json::Number::from(v as u64))
}

