/// Records table — all fixtures/records for this domain
fn records_table(rt: &Runtime) -> String {
    if rt.domain.fixtures.is_empty() {
        return r#"<div class="p-8 rounded-lg border border-dashed border-surface-4 text-center">
  <p class="text-gray-500">No records yet — use the palette above to dispatch a command</p>
</div>"#.to_string();
    }
    fixtures_section(&rt.domain.fixtures)
}

