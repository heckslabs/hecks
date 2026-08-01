use std::fmt;

// THE CLOSED SETS COME FROM THE LANGUAGE, not from here. `MutationOp` and
// `WhereOp` are declared by `Vocabulary` in the bluebook chapter and PROJECTED
// into Rust source by `bin/ir_vocabulary` ; re-exported so every consumer's
// `use crate::ir::*` reaches them at the same path as when they were written
// here by hand. Both had drifted while they were hand-written — eleven mutation
// ops against the four the language admits, and a ninth where-op it never
// declared — which is the whole argument for projecting them.
pub use super::ir_vocabulary::{MutationOp, WhereOp};

// THE CATEGORY SHAPES COME FROM THE LANGUAGE TOO, one rung further along than
// the closed sets above. `bin/ir_structs` reads the thirteen categories the
// language uses to describe itself, plus the `derived:` column of
// `assembly/contracts.rb` — the one thing the language cannot say, which fields
// the IR does not carry and why — and emits these nine as Rust source.
//
// Only ten, and that is the honest number: the rest of this file is here
// because the language and Rust genuinely disagree about it, or because the
// language never declared it at all. `ir_structs.rs`'s header names every one
// of those and says which. Re-exported so `use crate::ir::*` reaches them at
// the path they were written at by hand.
//
// ProcessManager and ProcessManagerHandler joined the list once the LANGUAGE
// was corrected, not Rust: it declared `ends_on` required where both runtimes
// have always held it optional, and `from_state` optional where neither runtime
// can parse a leg without one. Both structs came out of the generator identical,
// field for field and in order, to the hand-written ones deleted from here.
//
// WhereClause joined them once the LANGUAGE grew a word rather than once Rust
// changed: `op` has always been a `WhereOp` here, and the set it reads is one
// the language declares (Vocabulary::QueryComparator), but nothing LINKED the
// two, so the generator refused to guess the typing and said so. `Filter.op`
// now says `admits: Vocabulary::QueryComparator`, and what comes out is
// identical, field for field, to the struct deleted from here.
pub use super::ir_structs::{
    Aggregate, Command, Domain, Entity, Given, ProcessManager, ProcessManagerHandler, ReadModel,
    Transition, WhereClause,
};

#[derive(Debug, Clone)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, ValueSpec)>,
}

#[derive(Debug, Clone)]
pub enum ValueSpec {
    Literal {
        value: String,
    },
    FromEvent {
        name: String,
        default: Option<String>,
    },
    FromPm {
        name: String,
        default: Option<String>,
    },
    FromIter {
        field: String,
    },
}

// NO `identity_key`. Both `Aggregate` and `Entity` used to answer "the one
// path a repository addresses records by" — `identified_by.first()` — and the
// only thing that ever asked was `PersistenceAdapter::id_for_command`, which
// minted. A repository is handed an id ALREADY DERIVED: `identity::of` follows
// every declared path and joins them on `Naming::IDENTITY_JOIN`. So a store
// never had the question, and answering it with the first of several paths was
// a wrong answer nobody heard.


#[derive(Debug, Clone)]
pub struct AggregateHead {
    pub aggregate: String,
    /// SPELLED `as`, the way Ruby spells it and the way the wire has always
    /// carried it. A Rust keyword, so it takes the one mechanical escape a
    /// generator has to know: `r#`.
    pub r#as: String,
    pub many: bool,
}

#[derive(Debug, Clone)]
pub struct Attribute {
    pub name: String,
    /// SPELLED `type`, matching Ruby, escaped because Rust reserves the word.
    pub r#type: String,
    pub default: Option<String>,
    pub list: bool,
    pub optional: bool,
    pub enum_values: Vec<String>,
    pub pattern: Option<String>,
    /// The closed set this value must belong to, named where it was declared —
    /// `"Vocabulary::MutationOp"`. Qualified by the aggregate that holds it,
    /// because a closed set is a value object INSIDE an aggregate.
    ///
    /// The NAME crosses, not the members: each runtime resolves it against its
    /// own IR, so neither keeps a copy of a set the other declared. Unlike
    /// `enum_values` beside it — which `one_of` desugars away into a synthesised
    /// value object — this names a set that already exists and is left alone.
    pub admits: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
}

#[derive(Debug, Clone)]
pub struct Mutation {
    pub target: String,
    pub op: MutationOp,
    pub source: String,
}

#[derive(Debug, Clone)]
pub struct ValueObject {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub members: Vec<Vec<(String, String)>>,
    /// A one_of DECLARED but left empty is indistinguishable from no one_of at
    /// all if only `members` is carried — both are empty. Recording the
    /// declaration lets the language judge an empty closed set, the same way an
    /// empty attribute name survives into the IR and is judged there.
    pub closed_set: bool,
}

#[derive(Debug, Clone)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
}

impl Policy {
    pub fn event_qualifier(&self) -> Option<&str> {
        crate::naming::qualifier(&self.on_event)
    }

    pub fn event_name(&self) -> &str {
        crate::naming::unqualified(&self.on_event)
    }
}

#[derive(Debug, Clone)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<Transition>,
}

#[derive(Debug, Clone)]
pub struct OrderBy {
    pub field: String,
    pub direction: Direction,
}

#[derive(Debug, Clone)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone)]
pub struct LimitSpec {
    pub value: String,
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{}", self.name)?;
        let agg_count = self.aggregates.len();
        for (ai, agg) in self.aggregates.iter().enumerate() {
            let is_last_agg = ai == agg_count - 1;
            let prefix = if is_last_agg {
                "└──"
            } else {
                "├──"
            };
            let cont = if is_last_agg { "    " } else { "│   " };
            writeln!(
                f,
                "{} {} — {}",
                prefix,
                agg.name,
                agg.description.as_deref().unwrap_or("")
            )?;
            let cmd_count = agg.commands.len();
            for (ci, cmd) in agg.commands.iter().enumerate() {
                let cmd_prefix = if ci == cmd_count - 1 {
                    "└──"
                } else {
                    "├──"
                };
                write!(f, "{}{} {}", cont, cmd_prefix, cmd.name)?;
                if !cmd.emits.is_empty() {
                    write!(f, " -> {}", cmd.emits.join(", "))?;
                }
                writeln!(f)?;
            }
        }
        if !self.policies.is_empty() {
            for pol in &self.policies {
                writeln!(
                    f,
                    "  {} : {} -> {}",
                    pol.name, pol.on_event, pol.trigger_command
                )?;
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct Invariant {
    pub description: String,
    pub canonical: String,
}

