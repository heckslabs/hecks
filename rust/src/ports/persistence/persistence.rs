
use crate::hecksagon_parser;
use crate::ports::loading;
use crate::world::parser as world_parser;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct Persistence {
    pub adapter: String,
    pub settings: HashMap<String, String>,
}

impl Persistence {
    pub fn path(&self, bluebook_path: &str, field: &str) -> Option<PathBuf> {
        let domain_dir = Path::new(bluebook_path).parent()?.parent()?;
        self.settings.get(field).map(|value| domain_dir.join(value))
    }
}

pub const DEFAULT_ADAPTER: &str = "Memory";

pub fn resolve_for(bluebook_path: &str, aggregate: &str) -> Result<Persistence, String> {
    let bluebook_dir = Path::new(bluebook_path).parent();
    let declared = bluebook_dir.map(binds).unwrap_or_default();

    let adapter = match persisted_by(&declared, aggregate) {
        Some(adapter) => adapter,
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

fn has_hecksagon(bluebook_dir: Option<&Path>) -> bool {
    bluebook_dir
        .map(|dir| !loading::declarations(dir, "hecksagon").is_empty())
        .unwrap_or(false)
}

fn binds(bluebook_dir: &Path) -> Vec<(String, String)> {
    let mut found = Vec::new();
    for source in loading::declarations(bluebook_dir, "hecksagon") {
        let hexagon = hecksagon_parser::parse(&source);

        for binding in hexagon.bindings.iter().filter(|b| b.verb == "persisted_by") {
            found.push((binding.aggregate.clone(), binding.adapter.clone()));
        }
        if let Some(persistence) = hexagon.persistence.clone() {
            found.push((String::new(), persistence));
        }
    }
    found
}

fn persisted_by(declared: &[(String, String)], aggregate: &str) -> Option<String> {
    declared
        .iter()
        .find(|(named, _)| named.rsplit("::").next().unwrap_or(named) == aggregate)
        .or_else(|| declared.iter().find(|(named, _)| named.is_empty()))
        .map(|(_, adapter)| adapter.clone())
}

fn settings_for(bluebook_path: &str, adapter: &str) -> HashMap<String, String> {
    let Some(bluebook_dir) = Path::new(bluebook_path).parent() else {
        return HashMap::new();
    };
    let wanted = adapter.to_lowercase();

    for source in loading::declarations(bluebook_dir, "world") {
        let world = world_parser::parse(&source);

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

    HashMap::new()
}
