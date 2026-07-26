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
use std::path::{Path, PathBuf};

pub struct Persistence {
    pub adapter: String,
    pub database: PathBuf,
}

pub fn resolve(bluebook_path: &str) -> Option<Persistence> {
    let bluebook = Path::new(bluebook_path);
    let bluebook_dir = bluebook.parent()?;
    let domain_dir = bluebook_dir.parent()?;

    let adapter = persisted_by(bluebook_dir)?;
    let database = database_path(bluebook_dir, &adapter)?;

    Some(Persistence {
        adapter,
        database: domain_dir.join(database),
    })
}

/// The adapter named by a `persisted_by` bind in the hecksagon.
fn persisted_by(bluebook_dir: &Path) -> Option<String> {
    for source in loading::declarations(bluebook_dir, "hecksagon") {
        let hexagon = hecksagon_parser::parse(&source);

        if let Some(binding) = hexagon.bindings.iter().find(|b| b.verb == "persisted_by") {
            return Some(binding.adapter.clone());
        }
        // The older single-slot form, still understood by the parser.
        if let Some(persistence) = hexagon.persistence.clone() {
            return Some(persistence);
        }
    }
    None
}

/// The `database` value declared under the same how-verb in the world.
///
/// A verb-call block - `persisted_by("Sqlite") do database "..." end` - lands in
/// `configs`, keyed by the ADAPTER NAME lowercased. `adapter_bindings` is a
/// different shape entirely (the `adapter "Name" do ... end` form), and looking
/// there first is what made this resolve to nothing while every parse was
/// working correctly.
fn database_path(bluebook_dir: &Path, adapter: &str) -> Option<String> {
    let wanted = adapter.to_lowercase();

    for source in loading::declarations(bluebook_dir, "world") {
        let world = world_parser::parse(&source);

        let matching = world
            .configs
            .iter()
            .find(|config| config.name.to_lowercase() == wanted)
            .or_else(|| world.configs.first());

        if let Some(config) = matching {
            if let Some((_, value)) = config.values.iter().find(|(key, _)| key == "database") {
                return Some(value.clone());
            }
        }
    }
    None
}
