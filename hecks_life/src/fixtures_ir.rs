//! IR for .fixtures files. A fixtures file holds seed records grouped
//! by aggregate, parsed from the standalone `Hecks.fixtures` DSL:
//!
//!   Hecks.fixtures "Pizzas" do
//!     aggregate "Pizza" do
//!       fixture "Margherita", name: "Margherita", description: "Classic"
//!       fixture "Pepperoni",  name: "Pepperoni",  description: "Spicy"
//!     end
//!     aggregate "Order" do
//!       fixture "PendingOrder", customer_name: "Sample", quantity: 1
//!     end
//!   end
//!
//! The IR keeps the same `Fixture` struct used by the bluebook IR (see
//! `ir::Fixture`) — same shape, same downstream consumers (heki seed
//! loader, behaviors test setups). What changes is *where* fixtures
//! live (their own file, no longer mixed into the source bluebook).
//!
//! The `catalogs` map is the i42 catalog-dialect extension: an
//! aggregate declared with a `schema:` kwarg on the `aggregate` line
//! is a fixture-only reference table ("catalog") that carries its own
//! row schema, so no bluebook declaration is needed. Aggregates
//! without `schema:` behave exactly as before (catalogs map stays
//! empty for those).

use std::collections::BTreeMap;

use crate::ir::Fixture;

/// A parsed .fixtures file. The `domain_name` matches the source
/// bluebook's `Hecks.bluebook "X"` so a runtime can pair them up.
///
/// `catalogs` is keyed by aggregate name (matching each catalog's
/// `aggregate "X", schema: { … } do`) and holds the declared row
/// schema. BTreeMap gives deterministic iteration order — the parity
/// contract needs Ruby/Rust emissions to diff cleanly.
pub struct FixturesFile {
    pub domain_name: String,
    pub fixtures: Vec<Fixture>,
    pub catalogs: BTreeMap<String, Vec<CatalogAttr>>,
}

/// One attribute in a catalog's row schema. `name` is the attribute
/// key as it appears in fixture rows (`ext:` → `"ext"`); `type_name`
/// is the declared Ruby-ish type token verbatim (`"String"`,
/// `"Integer"`, `"list_of(String)"`) so the parity harness can diff
/// Ruby and Rust output character-for-character.
pub struct CatalogAttr {
    pub name: String,
    pub type_name: String,
}
