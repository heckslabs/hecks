//! Cross-aggregate reference dereference for `given`/`ensures` clauses.
//! Rust counterpart of `CommandRules::References#dereference` (references.rb).

use super::{Field, Fielded, Value};

/// A declared `reference_to`/`belongs_to` field: stored name, clause name, target aggregate.
#[derive(Clone, Copy)]
pub struct ReferenceSpec {
    pub field: &'static str,
    pub as_name: &'static str,
    pub target: &'static str,
}

/// Per-aggregate reference specs keyed by fully qualified aggregate name.
pub type ReferenceTable = &'static [(&'static str, &'static [ReferenceSpec])];

/// Maximum hops followed; bounds recursion on cyclic references.
// A cycle (A -> B -> A) is representable in `ReferenceTable`, so recursion needs a floor.
pub const DEREFERENCE_DEPTH: usize = 4;

/// Fetches a record by aggregate name and id, type-erased behind `Fielded`.
// Reachable only through `store`: resolve into owned `DerefNode`s before the mutable borrow.
pub trait ReferenceLookup {
    fn find_fielded(&self, target: &str, id: &str) -> Option<Box<dyn Fielded>>;
}

fn specs_for(table: ReferenceTable, target: &str) -> &'static [ReferenceSpec] {
    table.iter().find(|(name, _)| *name == target).map(|(_, specs)| *specs).unwrap_or(&[])
}

/// A fetched record plus its dereferenced nested references.
pub struct DerefNode {
    id: String,
    base: Box<dyn Fielded>,
    nested: Vec<(&'static str, DerefNode)>,
}

impl Fielded for DerefNode {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        // `nested` is checked first so a reference name beats a same-named field.
        if let Some((_, node)) = self.nested.iter().find(|(n, _)| *n == name) {
            return Some(Field::Nested(node));
        }
        self.base.field(name)
    }

    // `Value` has no map variant; equal ids mean the same reference.
    fn as_scalar(&self) -> Option<Value> {
        Some(Value::Str(self.id.clone()))
    }
    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        self.base.items(name)
    }
}

fn deref_layer(lookup: &dyn ReferenceLookup, table: ReferenceTable, specs: &'static [ReferenceSpec], source: &dyn Fielded, depth: usize) -> Vec<(&'static str, DerefNode)> {
    if depth == 0 {
        return Vec::new();
    }

    specs
        .iter()
        .filter_map(|spec| {
            let Some(Field::Value(Value::Str(id))) = source.field(spec.field) else { return None };
            // Absent or dangling ids are skipped, not refused: direct ones were already checked.
            if id.is_empty() {
                return None;
            }

            let base = lookup.find_fielded(spec.target, &id)?;
            let nested = deref_layer(lookup, table, specs_for(table, spec.target), base.as_ref(), depth - 1);
            Some((spec.as_name, DerefNode { id, base, nested }))
        })
        .collect()
}

/// Dereferences an aggregate/entity's stored reference fields, spread across top-level names.
pub fn owner_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, target: &'static str, id: &str) -> Vec<(&'static str, DerefNode)> {
    let Some(base) = lookup.find_fielded(target, id) else { return Vec::new() };
    deref_layer(lookup, table, specs_for(table, target), base.as_ref(), DEREFERENCE_DEPTH)
}

/// Wraps an entity command's parent aggregate as one dereferenced node.
pub fn parent_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, target: &'static str, id: &str) -> Option<DerefNode> {
    let base = lookup.find_fielded(target, id)?;
    let nested = deref_layer(lookup, table, specs_for(table, target), base.as_ref(), DEREFERENCE_DEPTH);
    Some(DerefNode { id: id.to_string(), base, nested })
}

/// Dereferences a command's reference-typed arguments.
pub fn command_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, specs: &'static [ReferenceSpec], args: &dyn Fielded) -> Vec<(&'static str, DerefNode)> {
    deref_layer(lookup, table, specs, args, DEREFERENCE_DEPTH)
}

/// The `Fielded` view `given`/`ensures` read: `command_deref`, then `args`, then `owner_deref`.
pub struct WithReferences<'a> {
    pub command_deref: &'a [(&'static str, DerefNode)],
    pub args: &'a dyn Fielded,
    pub owner_deref: &'a [(&'static str, DerefNode)],
}

impl<'a> Fielded for WithReferences<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        // `command_deref` must win: an aliased reference shares its name with the raw id argument.
        if let Some((_, node)) = self.command_deref.iter().find(|(n, _)| *n == name) {
            return Some(Field::Nested(node));
        }
        if let Some(f) = self.args.field(name) {
            return Some(f);
        }
        if let Some((_, node)) = self.owner_deref.iter().find(|(n, _)| *n == name) {
            return Some(Field::Nested(node));
        }
        None
    }
    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        self.args.items(name)
    }
}

/// A `projects` field: its name, the reference it follows, and the remote field it reads.
pub struct ProjectedFieldSpec {
    pub field: &'static str,
    pub reference: &'static str,
    pub remote_field: &'static str,
}

/// Reads each projected field off the already-dereferenced references.
pub fn seeded_projections(with_references: &dyn Fielded, specs: &'static [ProjectedFieldSpec]) -> Vec<(&'static str, Option<String>)> {
    specs
        .iter()
        .map(|spec| {
            // Only `Option<String>` remote fields are seeded; other types would need a coercion.
            let value = match with_references.field(spec.reference) {
                Some(Field::Nested(node)) => match node.field(spec.remote_field) {
                    Some(Field::Value(Value::Str(s))) => Some(s),
                    // A single-field value object unwraps to its one scalar, as Ruby's RebuildSweep does.
                    Some(Field::Nested(inner)) => match inner.as_scalar() {
                        Some(Value::Str(s)) => Some(s),
                        _ => None,
                    },
                    _ => None,
                },
                _ => None,
            };
            (spec.field, value)
        })
        .collect()
}

/// Write side of `projects`: one generated match arm per projected field.
pub trait SetProjectedField {
    fn set_projected_field(&mut self, name: &'static str, value: Option<String>);
}
