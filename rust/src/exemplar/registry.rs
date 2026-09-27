// Exemplar shapes for rust/project/registry.rb; see mod.rs.
// `InMemoryRepository<T>` only needs `T: Clone`, so an `i64` record type suffices.
#![allow(dead_code, unused_variables)]

// `QUERIES` and `AUTHORIZATION_ASSIGNMENTS` are defined beside `dispatch_by_name` in every
// generated registry; `check_role_via` needs them. Empty here: only the call shape is proven.
static QUERIES: &[crate::kernel::QueryDef] = &[];
static AUTHORIZATION_ASSIGNMENTS: Option<&str> = None;

fn tmpl_role_check_host(store: &TmplStore2, caller_role: Option<&str>, caller_actor_id: Option<&str>) -> Result<(), crate::kernel::Refusal> {
    // TMPL:role_check BEGIN
    crate::kernel::check_role_via(Some("TmplRole"), "TmplCommandName", caller_role, caller_actor_id, &*store, QUERIES, AUTHORIZATION_ASSIGNMENTS)?;
    // TMPL:role_check END
    Ok(())
}

struct TmplStore {
    tmpl_target_mod: crate::kernel::InMemoryRepository<i64>,
}

struct TmplRefItem {
    tmpl_element_field: String,
}

struct TmplRefArgs {
    tmpl_field: String,
    tmpl_optional_field: Option<String>,
    tmpl_list_field: Vec<TmplRefItem>,
}

fn tmpl_reference_check_required_host(store: &TmplStore, args: &TmplRefArgs) -> Result<(), crate::kernel::Refusal> {
    // TMPL:reference_check_required BEGIN
    crate::kernel::check_reference(&store.tmpl_target_mod, &args.tmpl_field, "TmplTarget", "tmpl_heads")?;
    // TMPL:reference_check_required END
    Ok(())
}

fn tmpl_reference_check_optional_host(store: &TmplStore, args: &TmplRefArgs) -> Result<(), crate::kernel::Refusal> {
    // TMPL:reference_check_optional BEGIN
    if let Some(v) = &args.tmpl_optional_field { crate::kernel::check_reference(&store.tmpl_target_mod, v, "TmplTarget", "tmpl_heads")?; }
    // TMPL:reference_check_optional END
    Ok(())
}

// One `check_reference` per element of a list argument that `sets` a `has_many` field.
fn tmpl_reference_check_list_host(store: &TmplStore, args: &TmplRefArgs) -> Result<(), crate::kernel::Refusal> {
    // TMPL:reference_check_list BEGIN
    for item in &args.tmpl_list_field { crate::kernel::check_reference(&store.tmpl_target_mod, &item.tmpl_element_field, "TmplTarget", "tmpl_heads")?; }
    // TMPL:reference_check_list END
    Ok(())
}

// `registry_file` — the whole per-domain registry.rs. The variable-arity blocks stay opaque
// Ruby-built markers; this shape proves the fixed skeleton around them.
fn tmpl_store_fields_placeholder() -> crate::kernel::InMemoryRepository<i64> {
    crate::kernel::InMemoryRepository::new()
}
fn tmpl_dump_arm_placeholder() {}
fn tmpl_seed_arm_placeholder() {}
fn tmpl_query_arm_placeholder() {}
fn tmpl_dispatch_arm_placeholder() -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {
    Ok(Vec::new())
}

// Two `unused_mut` warnings come from this exemplar only: `mut` is needed once real loop
// bodies replace the placeholders, and an allow would have to sit inside the fence.
// The generated file header lives outside the fence (a `#![...]` is legal only first in a file).
// TMPL:registry_file BEGIN
// `Clone` — a dry run (`cli::run`'s `{"dry_run": …}` step, `cli::serve`'s
// `snapshot`/`restore`) dispatches against a throwaway copy of the whole
// store: givens, mutations, ensures all run for real, nothing is kept.
#[derive(Clone)]
pub struct TmplStore2 {
    pub tmpl_field: crate::kernel::InMemoryRepository<i64>,
}

impl TmplStore2 {
    pub fn new() -> Self {
        Self {
            tmpl_field: tmpl_store_fields_placeholder(),
        }
    }

    /// Every aggregate this domain declared, dumped as
    /// "Domain::Aggregate#id" -> its own to_json() — the exact key
    /// shape bin/rust_conformance's own comparable["instances"]
    /// builds from Ruby (Fuzzing::Replay.call's own instance key
    /// format, read directly).
    pub fn instances(&self) -> Vec<(String, crate::kernel::Json)> {
        let mut instances = Vec::new();
tmpl_dump_arm_placeholder();
        instances
    }

    /// Seeds a fresh `Store` from a prior `instances()` dump —
    /// the exact "Domain::Aggregate#id" -> state shape, read
    /// back instead of written. Not `Result`-returning on a
    /// non-Object `seed`: an absent/malformed seed just yields
    /// an empty Store, the same starting point `Store::new()`
    /// already gives a caller with no prior state to seed from.
    pub fn from_seed(seed: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
        let mut store = Self::new();
        if let crate::kernel::Json::Object(fields) = seed {
            for (key, value) in fields {
tmpl_seed_arm_placeholder();
            }
        }
        Ok(store)
    }
}

/// `AggregateScan` — kernel/repository.rs's own trait, given a real
/// per-aggregate body here: one `if` per aggregate this domain declared,
/// the same "Domain::Aggregate" prefix `instances()`'s own dump arms
/// already use, each returning that one aggregate's own (id, to_json())
/// listing straight off its repository's `entries()`. Falls through to
/// the trait's own default (`None`) for any prefix that matches none of
/// them — kernel/cli.rs turns that into a clean "unknown aggregate"
/// refusal, never a panic.
impl crate::kernel::AggregateScan for TmplStore2 {
    fn scan(&self, aggregate: &str) -> Option<Vec<(String, crate::kernel::Json)>> {
tmpl_query_arm_placeholder();
        None
    }
}

pub fn dispatch_by_name(
    store: &mut TmplStore2,
    verb: &str,
    args_json: &crate::kernel::Json,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
    mutations: &mut Vec<crate::kernel::MutationRecord>,
) -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {
    match verb {
"tmpl_verb" => { tmpl_dispatch_arm_placeholder() }
        other => Err(crate::kernel::Refusal::TypeMismatch(format!("unknown command {other:?}"))),
    }
}

/// Ruby's own event payload is `payload: args` — the whole hash the
/// caller passed to `dispatch`, not filtered to the command's own
/// declared attributes (an identity-reference argument like
/// `number:` is not a declared `CreditArgs` field, and still shows
/// up on `AccountCredited`'s payload). `args.to_json()` inside each
/// generated `dispatch_*` only ever sees the narrowed, typed args
/// struct, so it structurally can't reproduce that — this replaces
/// whatever payload the generated dispatch built with the raw,
/// unfiltered `args_json` this router itself received, after the
/// fact, once dispatch has already decided whether to accept it.
/// Load-bearing for process managers, not just payload fidelity: a
/// saga leg that forwards `reference: :reference` into `Account.
/// Debit` (which doesn't declare a `reference` attribute) needs
/// that field to survive onto `AccountDebited`'s own payload for
/// `correlates_by` to find it downstream.
fn stamp_payload(events: Vec<crate::kernel::Event>, args_json: &crate::kernel::Json) -> Vec<crate::kernel::Event> {
    events.into_iter().map(|e| crate::kernel::Event { payload: args_json.clone(), ..e }).collect()
}
// TMPL:registry_file END
