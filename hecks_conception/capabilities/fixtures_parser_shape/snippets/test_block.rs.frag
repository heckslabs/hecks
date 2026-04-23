#[cfg(test)]
mod tests {
    use super::*;

    // Tiny helper: parse a source snippet and return the catalogs
    // map. Keeps the assertion surface focused on the i42 add.
    fn catalogs_of(source: &str) -> std::collections::BTreeMap<String, Vec<(String, String)>> {
        parse(source).catalogs
            .into_iter()
            .map(|(k, v)| (k, v.into_iter().map(|a| (a.name, a.type_name)).collect()))
            .collect()
    }

    #[test]
    fn schema_kwarg_records_one_catalog_attr() {
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "FlaggedExtension", schema: { ext: String } do
                fixture "Ruby", ext: "rb"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.len(), 1);
        assert_eq!(cats.get("FlaggedExtension").unwrap(),
                   &vec![("ext".into(), "String".into())]);
    }

    #[test]
    fn no_schema_kwarg_means_no_catalog_entry() {
        // Pre-i42 shape — unchanged behavior.
        let src = r#"
            Hecks.fixtures "Pizzas" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
            end
        "#;
        assert!(catalogs_of(src).is_empty());
    }

    #[test]
    fn schema_kwarg_records_multiple_attrs_in_order() {
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "ShebangMapping", schema: { match: String, ext: String } do
                fixture "Ruby", match: "ruby", ext: "rb"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.get("ShebangMapping").unwrap(), &vec![
            ("match".into(), "String".into()),
            ("ext".into(),   "String".into()),
        ]);
    }

    #[test]
    fn schema_kwarg_handles_list_of_parens() {
        // `list_of(String)` has a comma-free inner but the parens
        // must nest correctly so a schema like
        // `{ items: list_of(String), name: String }` splits on the
        // top-level comma only — not on a comma inside the parens.
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "TestCase", schema: { items: list_of(String), name: String } do
                fixture "Sample", items: ["a"], name: "sample"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.get("TestCase").unwrap(), &vec![
            ("items".into(), "list_of(String)".into()),
            ("name".into(),  "String".into()),
        ]);
    }

    #[test]
    fn nested_fixture_block_does_not_confuse_aggregate_scan() {
        // A fixture line that happens to contain `schema:` or nested
        // blocks shouldn't bleed into catalogs; only `aggregate` lines
        // feed the catalog extractor.
        let src = r#"
            Hecks.fixtures "Mixed" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
            end
        "#;
        let ff = parse(src);
        assert!(ff.catalogs.is_empty());
        assert_eq!(ff.fixtures.len(), 1);
        assert_eq!(ff.fixtures[0].aggregate_name, "Pizza");
    }

    #[test]
    fn plain_and_catalog_aggregates_coexist() {
        let src = r##"
            Hecks.fixtures "Mixed" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
              aggregate "Color", schema: { hex: String } do
                fixture "Red", hex: "#FF0000"
              end
            end
        "##;
        let ff = parse(src);
        assert_eq!(ff.catalogs.len(), 1);
        assert!(ff.catalogs.contains_key("Color"));
        assert!(!ff.catalogs.contains_key("Pizza"));
        // Fixtures from both aggregates still land in the flat list.
        assert_eq!(ff.fixtures.len(), 2);
    }
}
