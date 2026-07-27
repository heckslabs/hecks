//! persistence - the port's execution : resolve which adapter a domain bound,
//! and where that adapter points.
//!
//! The twin of lib/hecksagain/ports/persistence/persistence.rb. The domain never
//! says where it is stored. The HECKSAGON says which adapter
//! (`Pizzas::Pizza.persisted_by("Sqlite")`) and the WORLD says where that adapter
//! points (`database "data/pizzas.db"`). This reads both and hands back a path -
//! or nothing, when no persistence is bound and the runtime should stay in
//! memory.
//!
//! Reading the DECLARATIONS off a disk is not this port's job : that is the
//! loading port, and the Folder adapter behind it. What belongs here is the
//! resolution - given the declarations, which adapter and which location.
//!
//! The path is relative to the DOMAIN directory (the parent of bluebook/),
//! matching how the Ruby side resolves it. The two runtimes must land on the
//! same file or "they agree" would mean nothing.

use crate::hecksagon_parser;
use crate::ports::loading;
use crate::world::parser as world_parser;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct Persistence {
    pub adapter: String,
    /// The world block's values for this bind, VERBATIM.
    ///
    /// Not a resolved path. Each adapter names its own field — Sqlite declares
    /// `database` (a file), Heki declares `dir` (a folder holding one store per
    /// aggregate), Memory declares none — so the port carries the values and the
    /// adapter decides what they mean. Mirrors the `settings:` kwarg Ruby's port
    /// hands to `adapter_class(...).new`.
    pub settings: HashMap<String, String>,
}

impl Persistence {
    /// One setting, resolved against the DOMAIN directory when it is a path.
    ///
    /// The domain dir is the parent of `bluebook/`, matching how the Ruby side
    /// resolves it. The two runtimes must land on the same file or "they agree"
    /// would mean nothing.
    pub fn path(&self, bluebook_path: &str, field: &str) -> Option<PathBuf> {
        let domain_dir = Path::new(bluebook_path).parent()?.parent()?;
        self.settings.get(field).map(|value| domain_dir.join(value))
    }
}

/// The adapter the runtime always carries. The projection of Ruby's
/// `Ports::Persistence::DEFAULT_ADAPTER`.
pub const DEFAULT_ADAPTER: &str = "Memory";

/// The bind ONE aggregate resolves through — the one it declares, or the default.
///
/// PERSISTENCE BINDS PER AGGREGATE. This used to take the FIRST `persisted_by`
/// in the hecksagon and hand it to the whole domain, so a bluebook wiring
/// `Pizza.persisted_by("Sqlite")` beside `Cart.persisted_by("Memory")` bound
/// EVERYTHING to whichever the parser saw first — silently, with a domain that
/// looked entirely correct. Banking and pizzas are each uniformly bound, which
/// is why the corpus never showed it.
///
/// A DOMAIN WITH NO HECKSAGON gets Memory for every aggregate : wiring is
/// override, not substrate, so a bluebook runs before anyone has written one.
///
/// But a hecksagon IS EVIDENCE OF INTENT. Writing one says the wiring is being
/// decided, so an aggregate left out of it is a FORGOTTEN decision, not an
/// absent one — and defaulting there would be the silence this port exists to
/// refuse. `Err` is that case ; the caller refuses the boot.
///
/// Mirrors `bind_for` in lib/hecksagain/ports/persistence/persistence.rb, which
/// is the source of this behaviour — Ruby holds the semantics, this projects it.
pub fn resolve_for(bluebook_path: &str, aggregate: &str) -> Result<Persistence, String> {
    let bluebook_dir = Path::new(bluebook_path).parent();
    let declared = bluebook_dir.map(binds).unwrap_or_default();

    let adapter = match persisted_by(&declared, aggregate) {
        Some(adapter) => adapter,
        // No hecksagon at all : nothing was decided, so nothing was forgotten.
        None if declared.is_empty() && !has_hecksagon(bluebook_dir) => {
            DEFAULT_ADAPTER.to_string()
        }
        None => {
            return Err(format!(
                "{aggregate} has no persisted_by bind. This domain declares a hecksagon, \
                 so its wiring is being decided explicitly and an aggregate left out is a \
                 forgotten decision. Bind it, or say \
                 {aggregate}.persisted_by({DEFAULT_ADAPTER:?}) to keep it in memory on purpose."
            ))
        }
    };

    Ok(Persistence {
        settings: settings_for(bluebook_path, &adapter),
        adapter,
    })
}

/// Whether the domain declares a hecksagon at all — the intent signal. A
/// hecksagon that binds only OTHER verbs still counts : it is a file saying the
/// wiring is being decided.
fn has_hecksagon(bluebook_dir: Option<&Path>) -> bool {
    bluebook_dir
        .map(|dir| !loading::declarations(dir, "hecksagon").is_empty())
        .unwrap_or(false)
}

/// Every `persisted_by` bind the domain declares, as (aggregate FQN, adapter).
fn binds(bluebook_dir: &Path) -> Vec<(String, String)> {
    let mut found = Vec::new();
    for source in loading::declarations(bluebook_dir, "hecksagon") {
        let hexagon = hecksagon_parser::parse(&source);

        for binding in hexagon.bindings.iter().filter(|b| b.verb == "persisted_by") {
            found.push((binding.aggregate.clone(), binding.adapter.clone()));
        }
        // The older single-slot form, still understood by the parser. It names no
        // aggregate, so it applies to all of them — recorded with an empty name
        // and matched as a wildcard below.
        if let Some(persistence) = hexagon.persistence.clone() {
            found.push((String::new(), persistence));
        }
    }
    found
}

/// The adapter bound to ONE aggregate. The hecksagon names it by FQN
/// (`Pizzas::Pizza`), so the match is on the trailing segment — the projection
/// of Ruby's `Bind#aggregate_name`.
fn persisted_by(declared: &[(String, String)], aggregate: &str) -> Option<String> {
    declared
        .iter()
        .find(|(named, _)| named.rsplit("::").next().unwrap_or(named) == aggregate)
        .or_else(|| declared.iter().find(|(named, _)| named.is_empty()))
        .map(|(_, adapter)| adapter.clone())
}

/// THE WORLD BLOCK, HANDED OVER WHOLE.
///
/// This used to resolve a concrete `location: PathBuf` here, picking a value by
/// trying a hardcoded list of field names :
///
/// ```text
/// const LOCATION_FIELDS: [&str; 2] = ["database", "dir"];
/// ```
///
/// whose own comment admitted the problem — "knowledge about concrete adapters
/// sitting in the port, which is not ideal". It was worse than untidy. A port
/// that insists on a location cannot express an adapter that HAS none, so every
/// Memory bind resolved to nothing, which read as "no bind at all" and took the
/// grammar chapter down the moment an unbound aggregate became an error. Three
/// attempted fixes — an Option, a name check, a closure — were all shapes of the
/// same wrong idea.
///
/// Ruby never had the problem, because its port does not resolve a location :
///
/// ```text
/// settings = registry.world(domain)&.for_verb(bind.verb) || {}
/// registry.adapter_class(bind.adapter).new(aggregate:, settings:, root:)
/// ```
///
/// The adapter reads whichever field it declares — Sqlite `database`, Heki
/// `dir` — and Memory reads none, which is why it needs no world block at all.
/// This is the projection of that : the port carries the values, the adapter
/// decides what they mean.
fn settings_for(bluebook_path: &str, adapter: &str) -> HashMap<String, String> {
    let Some(bluebook_dir) = Path::new(bluebook_path).parent() else {
        return HashMap::new();
    };
    let wanted = adapter.to_lowercase();

    for source in loading::declarations(bluebook_dir, "world") {
        let world = world_parser::parse(&source);

        // A verb-call block — `persisted_by("Sqlite") do database "..." end` —
        // lands in `configs`, keyed by the ADAPTER NAME lowercased.
        // `adapter_bindings` is a different shape entirely (the
        // `adapter "Name" do ... end` form), and looking there first is what made
        // this resolve to nothing while every parse was working correctly.
        let matching = world
            .configs
            .iter()
            .find(|config| config.name.to_lowercase() == wanted)
            .or_else(|| world.configs.first());

        if let Some(config) = matching {
            return config
                .values
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
        }
    }

    // No world block is not a failure. Memory declares none, and an adapter that
    // needs a value says so when it looks and does not find one.
    HashMap::new()
}
