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

use crate::ir::Fixture;

/// A parsed .fixtures file. The `domain_name` matches the source
/// bluebook's `Hecks.bluebook "X"` so a runtime can pair them up.
pub struct FixturesFile {
    pub domain_name: String,
    pub fixtures: Vec<Fixture>,
}
