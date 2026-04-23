//! Parser for .fixtures files. Surface (kept small):
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
//! `fixture "Label", k: v, k2: v2` reuses the same comma-separated kwarg
//! parser as the bluebook IR's inline form (see parse_blocks::parse_fixture's
//! split_top_level_commas), so values can themselves contain commas
//! (quoted strings, arrays, hashes).
//!
//! The first positional arg of `fixture` is the label (Fixture::name);
//! everything after is k:v attributes. The enclosing `aggregate "X"`
//! block sets aggregate_name on each fixture inside.
//!
//! i42 catalog-dialect extension: an `aggregate` line may carry a
//! `schema:` kwarg whose value is an inline `{ k: Type, ... }` hash
//! literal. When present, the aggregate is a "catalog" — a
//! fixture-only reference table declaring its own row schema. The
//! schema is parsed into a `Vec<CatalogAttr>` and stored under the
//! aggregate's name in `FixturesFile::catalogs`. Aggregates without
//! `schema:` parse exactly as before.
//!
//!   aggregate "FlaggedExtension", schema: { ext: String } do
//!     fixture "Ruby", ext: "rb"
//!   end
//!
//! v1 constraint: single-line schema only. Multi-line schemas
//! (opening `{` on the aggregate line, closing `}` on a later line)
//! are not supported yet — see the plan's risk 9.1.
