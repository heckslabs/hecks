//! conception_kernel::grammar — the precondition taxonomy as DATA.
//!
//! Each KIND is a row (`KindRule`) composing three GENERAL primitives the
//! planner executes — there is no per-kind code in the engine. Adding a
//! list-ish kind is a new arm of `rule_for` (the table), with no change to
//! `planner.rs`. That property is the honesty test for "this is an interpreter,
//! not a refactor": the logic lives in the data, executed by generic primitives.
//!
//! Recognition of a `given` expression into a `Precondition` lives in
//! `recognize.rs` (the parse-shape half of the data layer).
//!
//! Example:
//!   let pre = recognize::parse_given("items.size >= 3").unwrap();
//!   assert_eq!(grammar::rule_for(pre.kind).producer, ProducerSeek::AppendN);

/// A `given` parsed into a precondition need.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Precondition {
    pub kind: Kind,
    pub field: String,
    /// Minimum count for list kinds (1 for NonEmptyList, N for MinSizeList).
    /// Zero for non-list kinds.
    pub count: i64,
    /// Match value for `Equals` (stringified). Empty for list kinds.
    pub value: String,
}

/// The closed set of kinds this slice's grammar can satisfy. A `Kind` is only a
/// tag that indexes the rule table — the planner NEVER matches on it, only on
/// the primitives a rule carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Equals,
    NonEmptyList,
    MinSizeList,
    EmptyList,
}

/// What mutation a producer must carry to satisfy a kind — a general primitive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProducerSeek {
    /// A `Set` mutation whose value equals the precondition's value.
    SetTo,
    /// One `Append` on the field.
    AppendOnce,
    /// `count` `Append`s on the field (existing appends subtracted by the
    /// planner so an already-seeded chain doesn't double-seed).
    AppendN,
    /// No producer — the kind is default-held.
    NoneNeeded,
}

/// How a kind is satisfied by already-produced facts — a general primitive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SatisfyPrimitive {
    /// `produced.set_facts` contains `(field, value)`.
    HasSetFact,
    /// `produced.append_count(field) >= count`.
    AppendCountAtLeast,
    /// Always satisfied (lists start empty).
    Always,
}

/// When the aggregate's defaults already hold the kind, no chain step is needed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DefaultRule {
    Always,
    Never,
}

/// One row of the taxonomy — pure data. Behaviour is the composition of the
/// three primitives; there is no per-kind control flow.
#[derive(Debug, Clone, Copy)]
pub struct KindRule {
    pub producer: ProducerSeek,
    pub default: DefaultRule,
    pub satisfy: SatisfyPrimitive,
}

/// The rule table — the grammar the planner reads. Each arm is a DATA row, not
/// a code path: the planner acts on `producer`/`default`/`satisfy`, never on the
/// `Kind` itself.
pub fn rule_for(kind: Kind) -> KindRule {
    match kind {
        Kind::Equals => KindRule {
            producer: ProducerSeek::SetTo,
            default: DefaultRule::Never,
            satisfy: SatisfyPrimitive::HasSetFact,
        },
        Kind::NonEmptyList => KindRule {
            producer: ProducerSeek::AppendOnce,
            default: DefaultRule::Never,
            satisfy: SatisfyPrimitive::AppendCountAtLeast,
        },
        Kind::MinSizeList => KindRule {
            producer: ProducerSeek::AppendN,
            default: DefaultRule::Never,
            satisfy: SatisfyPrimitive::AppendCountAtLeast,
        },
        Kind::EmptyList => KindRule {
            producer: ProducerSeek::NoneNeeded,
            default: DefaultRule::Always,
            satisfy: SatisfyPrimitive::Always,
        },
    }
}
