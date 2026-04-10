//! Domain IR — the intermediate representation
//!
//! Same structure as the Ruby BluebookModel, but in Rust.
//! This is what the parser produces and the generators consume.

use std::fmt;

#[derive(Debug)]
pub struct Domain {
    pub name: String,
    pub aggregates: Vec<Aggregate>,
    pub policies: Vec<Policy>,
    pub fixtures: Vec<Fixture>,
}

#[derive(Debug)]
pub struct Aggregate {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub commands: Vec<Command>,
    pub value_objects: Vec<ValueObject>,
    pub references: Vec<Reference>,
    pub lifecycle: Option<Lifecycle>,
}

#[derive(Debug)]
pub struct Attribute {
    pub name: String,
    pub attr_type: String,
    pub default: Option<String>,
    pub list: bool,
}

#[derive(Debug)]
pub struct Command {
    pub name: String,
    pub description: Option<String>,
    pub role: Option<String>,
    pub attributes: Vec<Attribute>,
    pub references: Vec<Reference>,
    pub emits: Option<String>,
    pub givens: Vec<Given>,
    pub mutations: Vec<Mutation>,
}

#[derive(Debug)]
pub struct Given {
    pub expression: String,
    pub message: Option<String>,
}

#[derive(Debug)]
pub struct Mutation {
    pub field: String,
    pub operation: MutationOp,
    pub value: String,
}

#[derive(Debug)]
pub enum MutationOp {
    Set,
    Append,
    Increment,
    Decrement,
    Toggle,
}

#[derive(Debug)]
pub struct ValueObject {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
}

#[derive(Debug)]
pub struct Reference {
    pub name: String,
    pub target: String,
    pub domain: Option<String>,
}

#[derive(Debug)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
}

#[derive(Debug)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<Transition>,
}

#[derive(Debug)]
pub struct Transition {
    pub command: String,
    pub to_state: String,
    pub from_state: Option<String>,
}

#[derive(Debug)]
pub struct Fixture {
    pub aggregate_name: String,
    pub attributes: Vec<(String, String)>,
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{} ({} aggregates)", self.name, self.aggregates.len())?;
        for agg in &self.aggregates {
            writeln!(f, "  {} — {}", agg.name, agg.description.as_deref().unwrap_or(""))?;
            for cmd in &agg.commands {
                let givens = cmd.givens.len();
                let mutations = cmd.mutations.len();
                write!(f, "    {}", cmd.name)?;
                if givens > 0 || mutations > 0 {
                    write!(f, " ({} givens, {} mutations)", givens, mutations)?;
                }
                if let Some(ref emits) = cmd.emits {
                    write!(f, " → {}", emits)?;
                }
                writeln!(f)?;
            }
        }
        Ok(())
    }
}
