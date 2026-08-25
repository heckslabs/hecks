// CROSS-AGGREGATE DEREFERENCE — `CommandRules::References#dereference`
// (lib/hecks/runtime/command_rules/references.rb), read directly.
// Ruby's own `given`/`ensures` clauses can name a HOP through a declared
// `reference_to`/`belongs_to` field (`customer.status`, `account.customer.
// status`, `parent.account.customer.status`) — resolved by fetching the
// referenced record through `@registry.repository(domain, target)` and
// merging its own state (recursively dereferenced one hop further, up to
// `DEREFERENCE_DEPTH`) under the field's own stripped `_id`-less name,
// BEFORE the expression is ever evaluated. This file is that same
// resolution, ported: a real repository lookup, not a static-shaped
// approximation — a fetched record's own `Fielded::field` impl (already
// generated, already type-correct: `Value::Int`/`Float`/`Str` exactly as
// declared) answers every scalar the way it always has, the SAME
// mechanism `command`/`aggregate`-level fields already use, just reached
// one hop later.
//
// WHY THIS IS BUILT OUTSIDE `kernel::dispatch`/`dispatch_entity`, NOT
// INSIDE THEM: resolving a reference needs `store` — every OTHER
// aggregate's repo, not just this command's own — which structurally
// only exists at the ROUTER level (`registry.rs`'s generated
// `dispatch_by_name`, the SAME reason `resolve_references`'s own
// existence check lives there and not in commands.rb — see dispatch.rs's
// own header). Borrowing `store` immutably (for a lookup) and
// `store.<this aggregate>` mutably (for the dispatch call itself) in the
// SAME expression would be two overlapping borrows of the same value —
// so the router resolves every reference into OWNED `DerefNode` data
// FIRST (a plain value, no longer borrowing `store` at all), and only
// THEN takes the mutable per-aggregate borrow `dispatch_by_name`'s own
// call already needed. `Store`'s generated `ReferenceLookup` impl is the
// one piece still reached through `store`, and only during that earlier,
// non-overlapping immutable phase.

use super::{Field, Fielded, Value};

/// One declared `reference_to`/`belongs_to` field, as data —
/// `rust/project/reference_specs.rb`'s own per-attribute walk
/// (`Attribute#reference?`, the SAME test `reactions.rb`'s own
/// `reference_target`/`naming.rb`'s own `reference_type?` already use for
/// the EXISTENCE check), computed once at codegen time. `field` is the
/// STORED attribute name (`"customer_id"`); `as_name` is what a `given`/
/// `ensures` clause actually writes (`"customer"` — the SAME `attribute.
/// name.to_s.sub(/_id\z/, "")` stripping `CommandRules::References
/// #dereference` uses); `target` is the fully domain-qualified aggregate
/// name (`"Banking::Customer"`) `ReferenceLookup::find_fielded` routes on.
#[derive(Clone, Copy)]
pub struct ReferenceSpec {
    pub field: &'static str,
    pub as_name: &'static str,
    pub target: &'static str,
}

/// Every generated aggregate's OWN reference specs, keyed by its fully
/// domain-qualified name — one static table per domain (`registry.rb`'s
/// own `emit_reference_table`), consulted by `deref_layer` to know how
/// to recurse ONE HOP FURTHER once it has fetched some target record: the
/// target's own specs are looked up here by name rather than threaded
/// through as a second parameter at every call site, since a spec's
/// `target` is already the only fact identifying which row applies.
pub type ReferenceTable = &'static [(&'static str, &'static [ReferenceSpec])];

/// Ruby's own `DEREFERENCE_DEPTH` (`references.rb`), read directly:
/// "nothing in this corpus dots more than two hops, and a bound is
/// simpler than tracking visited (type, id) pairs for a cycle nothing
/// here declares." Kept as the identical bound here for the identical
/// reason — a schema cycle (A references B, B references A) is
/// structurally representable in `ReferenceTable` (two static rows
/// pointing at each other), so recursion needs a hard floor regardless
/// of whether any REAL corpus declaration ever reaches it.
pub const DEREFERENCE_DEPTH: usize = 4;

/// `@registry.repository(domain, target).find(id)`, read directly — the
/// one piece of this mechanism that genuinely needs `store` (every
/// generated aggregate's own repo), so it's a trait `Store` itself
/// implements (`registry.rb`'s own generated `impl`), not a free
/// function. Returns the fetched record TYPE-ERASED but otherwise
/// UNCHANGED — the SAME generated `Fielded` impl every other lookup in
/// this kernel already trusts, so a fetched `Customer`'s `status` field
/// answers `Value::Str` exactly as declared, never a JSON-roundtripped
/// guess at its type.
pub trait ReferenceLookup {
    fn find_fielded(&self, target: &str, id: &str) -> Option<Box<dyn Fielded>>;
}

fn specs_for(table: ReferenceTable, target: &str) -> &'static [ReferenceSpec] {
    table.iter().find(|(name, _)| *name == target).map(|(_, specs)| *specs).unwrap_or(&[])
}

/// One fetched, recursively-dereferenced record — `base` answers every
/// field IT declares directly (`Fielded::field`, delegated), `nested`
/// answers the handful of names that are actually ANOTHER hop
/// (`"customer"` on a fetched `Account`), checked first so a reference
/// name never loses to a same-named literal field (nothing in this
/// corpus collides the two, but `nested` taking precedence matches
/// `dereference`'s own hydrated-hash-wins framing generally: the merge
/// this node represents is ALWAYS the higher-precedence side of
/// whichever tier constructed it). `id` is the key it was FETCHED by
/// (`ReferenceLookup::find_fielded`'s own argument) — kept alongside
/// `base`/`nested` purely for `as_scalar`, below.
pub struct DerefNode {
    id: String,
    base: Box<dyn Fielded>,
    nested: Vec<(&'static str, DerefNode)>,
}

impl Fielded for DerefNode {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        if let Some((_, node)) = self.nested.iter().find(|(n, _)| *n == name) {
            return Some(Field::Nested(node));
        }
        self.base.field(name)
    }

    /// `Resolver#unwrap_scalar`'s own fallthrough for a dereferenced
    /// reference, read directly: a BARE `source`/`destination` (no
    /// further dotted segment) doesn't unwrap to a single field the way
    /// a `{value: X}` VO does — Ruby's own version just returns the
    /// whole hydrated Hash, still comparable (`==`/`!=`) and testable
    /// (`.empty?`) generically. This kernel has no equivalent of "compare
    /// two arbitrary Hashes structurally" (`Value` has no `Hash`
    /// variant), so it collapses to the id it was fetched by instead —
    /// two dereferenced references are the same reference iff they
    /// resolved to the same id, which is what `source != destination`
    /// ("a transfer moves BETWEEN accounts") and `!source.empty?`
    /// actually need: a non-empty, comparable identity, not the full
    /// state. Observably identical to Ruby's own Hash-equality reading
    /// for every real dispatch this corpus exercises — a resolved
    /// reference's id already determines its whole fetched state.
    fn as_scalar(&self) -> Option<Value> {
        Some(Value::Str(self.id.clone()))
    }
    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        self.base.items(name)
    }
}

/// `CommandRules::References#dereference`'s own recursive body, read
/// directly: for every reference `specs` declares, read its id off
/// `source`, fetch the target, and recurse into THAT target's own specs
/// one hop further — `next if id.nil?` (an absent/empty id — no
/// reference set yet, e.g. `CardPayment#disputed_by` before the first
/// `Dispute`) and `next unless record` (a dangling id `ReferenceLookup`
/// can't resolve) are both silently skipped, never refused: by the time
/// evaluation reaches here, `resolve_references`'s own existence check
/// (`registry.rs`'s generated reference checks) has already run for
/// every reference THIS command declares directly — a still-missing hop
/// two levels down is exactly the "cannot resolve" a `Lookup` against it
/// would raise on its own, no different from Ruby's own `EvaluationError`
/// path.
fn deref_layer(lookup: &dyn ReferenceLookup, table: ReferenceTable, specs: &'static [ReferenceSpec], source: &dyn Fielded, depth: usize) -> Vec<(&'static str, DerefNode)> {
    if depth == 0 {
        return Vec::new();
    }

    specs
        .iter()
        .filter_map(|spec| {
            let Some(Field::Value(Value::Str(id))) = source.field(spec.field) else { return None };
            if id.is_empty() {
                return None;
            }

            let base = lookup.find_fielded(spec.target, &id)?;
            let nested = deref_layer(lookup, table, specs_for(table, spec.target), base.as_ref(), depth - 1);
            Some((spec.as_name, DerefNode { id, base, nested }))
        })
        .collect()
}

/// An AGGREGATE/ENTITY's OWN reference fields, dereferenced off its
/// STORED record (an ACTING command's own hydrated instance) —
/// `CommandRules::Admissibility#enforce_givens`'s own `dereference(domain,
/// owner, subject)`, read directly, spread across SEVERAL top-level
/// names (`"customer"`, not nested under one key). `target`/`id` name the
/// record to fetch; an id this lookup can't resolve, OR a CREATING
/// command (no record exists yet — its caller passes no `id` at all,
/// see `command_deref` below for why that's not a real gap), answers
/// with the empty list, same as Ruby's own `owner.nil?` guard.
pub fn owner_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, target: &'static str, id: &str) -> Vec<(&'static str, DerefNode)> {
    let Some(base) = lookup.find_fielded(target, id) else { return Vec::new() };
    deref_layer(lookup, table, specs_for(table, target), base.as_ref(), DEREFERENCE_DEPTH)
}

/// An ENTITY command's own PARENT aggregate, wrapped as ONE node —
/// `CommandRules::Admissibility#enforce_givens`'s own `parent:
/// dereference(domain, parent.aggregate, parent.state).merge(parent.
/// state)`, read directly: entity givens read the whole parent under ONE
/// name (`parent.account.customer.status`), not spread across top-level
/// keys the way an aggregate's OWN references are (`owner_deref`,
/// above) — `DerefNode`'s own shape (a base record PLUS its nested
/// further-dereferenced references) already answers both halves of that
/// merge directly, so this is `owner_deref`'s identical fetch, just kept
/// as one un-spread node instead of unpacked into a list.
pub fn parent_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, target: &'static str, id: &str) -> Option<DerefNode> {
    let base = lookup.find_fielded(target, id)?;
    let nested = deref_layer(lookup, table, specs_for(table, target), base.as_ref(), DEREFERENCE_DEPTH);
    Some(DerefNode { id: id.to_string(), base, nested })
}

/// A COMMAND's OWN reference-typed ARGUMENTS, dereferenced directly off
/// the already-typed, already-`from_json`'d `args` struct —
/// `CommandRules::References#dereference(domain, command, args)`, read
/// directly. No repository lookup is needed to find the SOURCE here
/// (`args` already IS it, unlike `owner_deref`'s `target`/`id` pair,
/// which still has to fetch the record it reads from) — only to resolve
/// what each reference-typed argument POINTS AT, the same
/// `deref_layer` every other tier reuses. Covers BOTH a creating
/// command's own reference arguments (`Account.Open`'s `customer_id` —
/// the ONLY tier available before the record exists at all, since
/// `owner_deref` needs an `id` a creating command's caller never has)
/// and an acting command's own extra reference arguments beyond its
/// identity target (`CardPayment.Dispute`'s `disputed_by`, unset on the
/// stored record until this very dispatch sets it).
pub fn command_deref(lookup: &dyn ReferenceLookup, table: ReferenceTable, specs: &'static [ReferenceSpec], args: &dyn Fielded) -> Vec<(&'static str, DerefNode)> {
    deref_layer(lookup, table, specs, args, DEREFERENCE_DEPTH)
}

/// The Fielded surface `given`/`ensures` evaluation actually reads as
/// `EvalContext.args` (dispatch.rs) — `CommandRules::Admissibility
/// #enforce_givens`'s own `attrs = dereference(domain, owner, subject).
/// merge(args).merge(dereference(domain, command, args))`, read
/// directly: `command_deref` wins ties (checked first — includes a
/// `"parent"` entry for an entity command, appended alongside its own
/// reference arguments by the generated caller), the untouched typed
/// `args` struct is checked second, `owner_deref` (an aggregate/entity's
/// own STORED reference fields) is checked last. MERGE ORDER MATTERS THE
/// SAME WAY IT DOES IN RUBY: an aliased command-level reference
/// (`reference_to Customer, as: :customer`) hydrates under the SAME name
/// the raw id argument already holds — `command_deref` must win that
/// collision, or a `.status` lookup would hit the raw id String instead
/// (Ruby's own comment on this exact bug, references.rb, read directly).
pub struct WithReferences<'a> {
    pub command_deref: &'a [(&'static str, DerefNode)],
    pub args: &'a dyn Fielded,
    pub owner_deref: &'a [(&'static str, DerefNode)],
}

impl<'a> Fielded for WithReferences<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
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
