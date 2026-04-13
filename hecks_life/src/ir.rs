//! Domain IR — the intermediate representation
//!
//! Same structure as the Ruby BluebookModel, but in Rust.
//! This is what the parser produces and the generators consume.

use std::fmt;

#[derive(Debug)]
pub struct Domain {
    pub name: String,
    pub category: Option<String>,
    pub vision: Option<String>,
    pub aggregates: Vec<Aggregate>,
    pub policies: Vec<Policy>,
    pub fixtures: Vec<Fixture>,
    pub vows: Vec<Vow>,
}

#[derive(Debug)]
pub struct Vow {
    pub name: String,
    pub text: String,
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

#[derive(Debug, Clone)]
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
        write!(f, "{} ({} aggregates)", self.name, self.aggregates.len())?;
        if let Some(ref cat) = self.category {
            write!(f, " [{}]", cat)?;
        }
        writeln!(f)?;
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
        if !self.policies.is_empty() {
            writeln!(f)?;
            writeln!(f, "Policies:")?;
            for pol in &self.policies {
                if let Some(ref target) = pol.target_domain {
                    writeln!(f, "  {} → {}:{}", pol.on_event, target, pol.trigger_command)?;
                } else {
                    writeln!(f, "  {} → {}", pol.on_event, pol.trigger_command)?;
                }
            }
        }
        if !self.vows.is_empty() {
            writeln!(f)?;
            writeln!(f, "Vows:")?;
            for vow in &self.vows {
                writeln!(f, "  {} — {}", vow.name, vow.text)?;
            }
        }
        Ok(())
    }
}
