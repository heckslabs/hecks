//! A domain's declared queries, interpreted from its canonical IR (ADR 0011, 0027, 0188 step 3).
//!
//! The rows `rust/codegen` writes as `QUERIES` and `ENTITY_QUERIES`, and the argument gate it
//! writes as `check_query_args`, read from the IR at run time. A host passes the IR under the
//! run's `"ir"` key (one domain object, or an array of them); without it the kernel keeps using
//! `generated::active`, so this is the second slice of dropping it, not the whole of it.
//!
//! A query answers one of three ways: a row (`Found`), no row because the generator would skip it
//! (`Missing`, refused as "not generated"), or a shape this reading does not cover (`Generated`,
//! which the caller answers from the generated tables).

mod arg_checks;
mod ast;
mod rows;
mod shape;
mod skip;
#[cfg(test)]
mod tests;

use super::named_query::{EntityQueryDef, QueryDef};
use super::{Json, Refusal};
use arg_checks::ArgCheck;
use rows::Scope;
use shape::{items, text_of};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};

/// What the IR says about one query verb.
pub enum Lookup<T> {
    /// Interpreted from the IR.
    Found(T),
    /// Declared without a generated row, or not declared at all.
    Missing,
    /// Declared in a shape this reading does not cover.
    Generated,
}

enum Entry<T> {
    Row(T),
    Skipped,
    Uncovered,
}

/// Every query of the IR it was built from, by verb, in declaration order.
pub struct IrQueries {
    named: Vec<(String, Entry<&'static QueryDef>)>,
    entities: Vec<(String, Entry<&'static EntityQueryDef>)>,
    gates: HashMap<String, Option<Vec<ArgCheck>>>,
}

fn domains(ir: &Json) -> &[Json] {
    match ir {
        Json::Array(domains) => domains,
        one => std::slice::from_ref(one),
    }
}

fn entry<T>(row: Option<T>) -> Entry<T> {
    row.map_or(Entry::Uncovered, Entry::Row)
}

impl IrQueries {
    /// Reads one domain's IR, or an array of them.
    pub fn from_ir(ir: &Json) -> Self {
        let mut built = Self {
            named: Vec::new(),
            entities: Vec::new(),
            gates: HashMap::new(),
        };
        for domain in domains(ir) {
            let aggregates = shape::by_name(domain, "aggregates");
            let name = text_of(domain, "name");
            for aggregate in items(domain, "aggregates") {
                built.read_aggregate(&Scope {
                    domain: &name,
                    aggregate,
                    aggregates: &aggregates,
                });
            }
        }
        built
    }

    fn read_aggregate(&mut self, scope: &Scope) {
        let objects = shape::by_name(scope.aggregate, "value_objects");
        let owner = text_of(scope.aggregate, "name");
        for query in items(scope.aggregate, "queries") {
            let verb = format!("{}::{owner}.{}", scope.domain, text_of(query, "name"));
            if skip::query_skipped(query, scope.aggregate, &objects, scope.aggregates) {
                self.named.push((verb, Entry::Skipped));
                continue;
            }
            self.gates.insert(
                verb.clone(),
                arg_checks::checks_for(query, &owner, &objects),
            );
            self.named
                .push((verb, entry(rows::query_def(scope, query))));
        }
        for entity in items(scope.aggregate, "entities") {
            self.read_entity(scope, entity, &objects);
        }
    }

    fn read_entity(&mut self, scope: &Scope, entity: &Json, objects: &shape::ByName) {
        let (owner, entity_name) = (text_of(scope.aggregate, "name"), text_of(entity, "name"));
        let list = items(scope.aggregate, "attributes")
            .iter()
            .find(|a| shape::is_list(a) && shape::type_name(a) == entity_name);
        for query in items(entity, "queries") {
            let verb = format!(
                "{}::{owner}.{entity_name}.{}",
                scope.domain,
                text_of(query, "name")
            );
            let list_name = list.map(|a| shape::name(a).to_string());
            if skip::entity_query_skipped(query, entity, list.is_some(), objects) {
                self.entities.push((verb, Entry::Skipped));
                continue;
            }
            let row =
                list_name.and_then(|name| rows::entity_query_def(scope, entity, &name, query));
            self.entities.push((verb, entry(row)));
        }
    }

    /// The row for a declared aggregate query verb.
    pub fn named(&self, verb: &str) -> Lookup<&'static QueryDef> {
        lookup(&self.named, verb)
    }

    /// The row for a declared entity query verb.
    pub fn entity(&self, verb: &str) -> Lookup<&'static EntityQueryDef> {
        lookup(&self.entities, verb)
    }

    /// Every interpreted aggregate query row, in declaration order.
    pub fn named_rows(&self) -> Vec<&'static QueryDef> {
        self.named
            .iter()
            .filter_map(|(_, e)| {
                if let Entry::Row(row) = e {
                    Some(*row)
                } else {
                    None
                }
            })
            .collect()
    }

    /// Every interpreted entity query row, in declaration order.
    pub fn entity_rows(&self) -> Vec<&'static EntityQueryDef> {
        self.entities
            .iter()
            .filter_map(|(_, e)| {
                if let Entry::Row(row) = e {
                    Some(*row)
                } else {
                    None
                }
            })
            .collect()
    }

    /// The argument gate of a query: `None` when it is not read from the IR, so the generated
    /// `check_query_args` answers.
    pub fn check_args(&self, verb: &str, args: &Json) -> Option<Result<(), Refusal>> {
        let checks = self.gates.get(verb)?.as_ref()?;
        Some(arg_checks::run(checks, args))
    }
}

fn lookup<T: Copy>(table: &[(String, Entry<T>)], verb: &str) -> Lookup<T> {
    match table.iter().find(|(name, _)| name == verb) {
        Some((_, Entry::Row(row))) => Lookup::Found(*row),
        Some((_, Entry::Uncovered)) => Lookup::Generated,
        _ => Lookup::Missing,
    }
}

/// Two FNV-style hashes of one walk of the IR: a 128-bit key, so a cache hit costs one pass and
/// no allocation.
struct Fingerprint([u64; 2]);

impl Fingerprint {
    fn mix(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.0[0] = (self.0[0] ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
            self.0[1] = (self.0[1] ^ u64::from(byte)).wrapping_mul(0x9e37_79b9_7f4a_7c15);
        }
    }

    fn walk(&mut self, json: &Json) {
        match json {
            Json::Object(fields) => {
                self.mix(b"{");
                for (key, value) in fields {
                    self.mix(key.as_bytes());
                    self.mix(b":");
                    self.walk(value);
                }
                self.mix(b"}");
            }
            Json::Array(items) => {
                self.mix(b"[");
                for item in items {
                    self.walk(item);
                }
                self.mix(b"]");
            }
            Json::Str(text) => {
                self.mix(b"\"");
                self.mix(text.as_bytes());
                self.mix(b"\"");
            }
            Json::Num(number, _) | Json::Float(number) => {
                self.mix(b"#");
                self.mix(&number.to_bits().to_le_bytes());
            }
            Json::Bool(flag) => self.mix(&[b'b', u8::from(*flag)]),
            Json::Null => self.mix(b"n"),
        }
    }
}

fn fingerprint(ir: &Json) -> (u64, u64) {
    let mut hashed = Fingerprint([0xcbf2_9ce4_8422_2325, 0x8422_2325_cbf2_9ce4]);
    hashed.walk(ir);
    (hashed.0[0], hashed.0[1])
}

/// The queries of `ir`, built once per distinct IR and kept for the life of the process, so a host
/// that sends the IR with every run pays the reading once. An IR is told apart by a 128-bit
/// fingerprint of its content.
pub fn for_ir(ir: &Json) -> &'static IrQueries {
    static BUILT: OnceLock<Mutex<HashMap<(u64, u64), &'static IrQueries>>> = OnceLock::new();
    let key = fingerprint(ir);
    let mut built = BUILT
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    built
        .entry(key)
        .or_insert_with(|| Box::leak(Box::new(IrQueries::from_ir(ir))))
}
