// DOMAINS PROJECTED INTO RUST, one file each, by `bin/ir_rust`.
//
// `ir_structs.rs` projects the SHAPES the language declares; this projects
// VALUES of them. A domain here is not parsed at boot and did not come from
// Ruby at run time — it is the domain, compiled.
//
// Checked in for the same reason the other projections are: Rust cannot run the
// Ruby DSL, so it compiles against a copy, and a copy nothing compares is a copy
// that drifts. `spec/ir_rust_export_spec.rb` holds each file to its generator
// AND flattens what it returns back through `ir_json::domain_to_value` to diff
// against Ruby's own `to_h`.
pub mod pizzas;

#[cfg(test)]
mod tests {
    /// THE PROJECTION IS HELD TO RUBY, not merely to itself.
    ///
    /// `spec/golden/ir/Pizzas.json` is Ruby's own `to_h`, frozen. This flattens
    /// the PROJECTED domain back through the same wire projector `--dump` uses
    /// and diffs the two. So the claim is not "the generator is deterministic"
    /// — it is "a domain compiled into Rust says exactly what Ruby says it is",
    /// which is `bin/parity`'s contract pointed at the projection.
    ///
    /// It is a real check and not a tautology: nothing about `domain()` came
    /// from this file's own reading of the bluebook. A mis-inverted mutation
    /// source, a dropped optional, a literal that lost its quotes — each fails
    /// here, and each is a mistake this codebase has made before through the
    /// same door.
    #[test]
    fn the_projected_domain_says_what_ruby_says() {
        let golden = std::fs::read_to_string(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../spec/golden/ir/Pizzas.json"),
        )
        .expect("spec/golden/ir/Pizzas.json — Ruby's frozen IR for the same chapter");

        let ruby: serde_json::Value =
            serde_json::from_str(&golden).expect("the golden is JSON");
        let projected = crate::projector::ir_json::domain_to_value(&super::pizzas::domain());
        let mine = projected
            .get("Pizzas")
            .expect("domain_to_value keys the body by chapter name");

        assert_eq!(
            mine, &ruby,
            "the projected Pizzas differs from Ruby's frozen IR"
        );
    }
}
