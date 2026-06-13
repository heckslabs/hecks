//! conception_kernel::grammar — the precondition taxonomy as DATA.
//!
//! Each KIND is a row (`KindRule`) composing GENERAL primitives the planner
//! executes — there is no per-kind code in the engine. Adding a kind is a new
//! arm of `rule_for` (the table), with no change to `planner.rs`. That property
//! is the honesty test for "interpreter, not refactor": the logic lives in the
//! data, executed by generic primitives.
//!
//! The integer kinds (slice 2) prove the design holds for a HARD case: their
//! satisfy predicate is a compound disjunction-with-negation, yet it is
//! expressed here as a composable `Satisfy` TREE over atomic predicates
//! (`SetFactInt`, `Incremented`) and boolean combinators — NOT an opaque kernel
//! function the grammar merely names. `GreaterThan` =
//!   Or(SetFactInt(Gt), And(Incremented, Not(SetFactInt(Le)))).
//!
//! Recognition of a `given` into a `Precondition` lives in `recognize.rs`.

/// A `given` parsed into a precondition need.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Precondition {
    pub kind: Kind,
    pub field: String,
    /// List kinds: minimum size. Integer kinds: the comparison operand `n`
    /// (what `satisfy` compares against). Zero otherwise.
    pub count: i64,
    /// Integer kinds: the value a producer must LAND the field at (n+1 for
    /// GreaterThan, n for GreaterOrEqual, n-1 for LessThan). Unused otherwise.
    pub target: i64,
    /// Match value for `Equals` (stringified). Empty otherwise.
    pub value: String,
}

/// The closed set of kinds the grammar can satisfy. A `Kind` is only a tag that
/// indexes the rule table — the planner NEVER matches on it, only on the
/// primitives a rule carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Equals,
    NonEmptyList,
    MinSizeList,
    EmptyList,
    GreaterThan,
    GreaterOrEqual,
    LessThan,
}

/// What mutation a producer must carry to satisfy a kind — a general primitive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProducerSeek {
    /// A `Set` whose value equals the precondition's value.
    SetTo,
    /// One `Append` on the field.
    AppendOnce,
    /// `count` `Append`s on the field (existing appends subtracted).
    AppendN,
    /// A `Set` landing the field at an integer >= `target`, or (when
    /// `target <= 1`) an `Increment` on the field.
    SetIntAtLeast,
    /// A `Set` landing the field at an integer <= `target`.
    SetIntAtMost,
    /// No producer — the kind is default-held.
    NoneNeeded,
}

/// Integer comparison — an atomic relation the `Satisfy` tree composes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Gt,
    Ge,
    Lt,
    Le,
}

impl CmpOp {
    pub fn apply(self, x: i64, n: i64) -> bool {
        match self {
            CmpOp::Gt => x > n,
            CmpOp::Ge => x >= n,
            CmpOp::Lt => x < n,
            CmpOp::Le => x <= n,
        }
    }
}

/// How a kind is satisfied by already-produced facts — a composable tree of
/// GENERAL atomic predicates and boolean combinators. The engine evaluates the
/// tree; the grammar decides its shape. This is what keeps the compound integer
/// predicate DATA rather than kernel logic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Satisfy {
    /// `produced.set_facts` contains `(field, value)`.
    HasSetFact,
    /// `produced.append_count(field) >= count`.
    AppendCountAtLeast,
    /// Some `set_fact` on the field parses to an integer `cmp` `count`.
    SetFactInt(CmpOp),
    /// The field was incremented by some chain step.
    Incremented,
    /// Some `set_fact` on the field whose value does NOT parse as an integer
    /// (a string/symbol Set). It trips the integer reset-guard — generator's
    /// guard treats a non-parseable fact as present (`unwrap_or(true)`), so a
    /// non-int Set on a counter field cancels the increment branch.
    SetFactNonInt,
    /// Always satisfied (lists start empty).
    Always,
    /// Never satisfied by chain steps (defaults handle it).
    Never,
    And(Box<Satisfy>, Box<Satisfy>),
    Or(Box<Satisfy>, Box<Satisfy>),
    Not(Box<Satisfy>),
}

/// When the aggregate's defaults already hold the kind, no chain step is needed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DefaultRule {
    /// Lists start empty — `EmptyList` holds.
    Always,
    /// A producer is always required.
    Never,
    /// `LessThan`: holds when `n > 0` and the field is an Integer attribute
    /// (integers default to 0, and `0 < n`).
    IfDefaultBelow,
    /// `Equals`: holds when the aggregate already starts at the value — the
    /// lifecycle default IS the value, or a Boolean/typed attribute's default
    /// IS the value. (A command transitioning TO the lifecycle default needs
    /// no setup; the aggregate is born there.)
    IfDefaultMatches,
}

/// One row of the taxonomy — data. Behaviour is the composition of the three
/// primitives; there is no per-kind control flow in the engine.
#[derive(Debug, Clone)]
pub struct KindRule {
    pub producer: ProducerSeek,
    pub default: DefaultRule,
    pub satisfy: Satisfy,
}

fn or(a: Satisfy, b: Satisfy) -> Satisfy {
    Satisfy::Or(Box::new(a), Box::new(b))
}
fn and(a: Satisfy, b: Satisfy) -> Satisfy {
    Satisfy::And(Box::new(a), Box::new(b))
}
fn not(a: Satisfy) -> Satisfy {
    Satisfy::Not(Box::new(a))
}

/// The rule table — the grammar the planner reads. Each arm is a DATA row: the
/// planner acts on `producer`/`default`/`satisfy`, never on the `Kind` itself.
pub fn rule_for(kind: Kind) -> KindRule {
    use CmpOp::*;
    use DefaultRule as D;
    use ProducerSeek as P;
    use Satisfy::*;
    match kind {
        Kind::Equals => KindRule {
            producer: P::SetTo,
            default: D::IfDefaultMatches,
            satisfy: HasSetFact,
        },
        Kind::NonEmptyList => KindRule {
            producer: P::AppendOnce,
            default: D::Never,
            satisfy: AppendCountAtLeast,
        },
        Kind::MinSizeList => KindRule {
            producer: P::AppendN,
            default: D::Never,
            satisfy: AppendCountAtLeast,
        },
        Kind::EmptyList => KindRule {
            producer: P::NoneNeeded,
            default: D::Always,
            satisfy: Always,
        },
        // x > n: a set landed it above n, OR it was incremented and nothing
        // reset it back to <= n.
        Kind::GreaterThan => KindRule {
            producer: P::SetIntAtLeast,
            default: D::Never,
            satisfy: or(
                SetFactInt(Gt),
                and(Incremented, not(or(SetFactInt(Le), SetFactNonInt))),
            ),
        },
        Kind::GreaterOrEqual => KindRule {
            producer: P::SetIntAtLeast,
            default: D::Never,
            satisfy: or(
                SetFactInt(Ge),
                and(Incremented, not(or(SetFactInt(Lt), SetFactNonInt))),
            ),
        },
        Kind::LessThan => KindRule {
            producer: P::SetIntAtMost,
            default: D::IfDefaultBelow,
            satisfy: Never,
        },
    }
}
