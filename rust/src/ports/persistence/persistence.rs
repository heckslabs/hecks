use crate::hecksagon_parser;
use crate::ports::loading;
use crate::world::parser as world_parser;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct Persistence {
    pub adapter: String,
    pub settings: HashMap<String, String>,
}

pub struct PersistenceBindings {
    pub authoritative: Persistence,
    pub mirrors: Vec<Persistence>,
}

impl Persistence {
    pub fn path(&self, bluebook_path: &str, field: &str) -> Option<PathBuf> {
        let domain_dir = Path::new(bluebook_path).parent()?.parent()?;
        self.settings.get(field).map(|value| domain_dir.join(value))
    }
}

pub const DEFAULT_ADAPTER: &str = "Memory";

pub fn resolve_for(bluebook_path: &str, aggregate: &str) -> Result<Persistence, String> {
    Ok(resolve_all_for(bluebook_path, aggregate)?.authoritative)
}

pub fn resolve_all_for(bluebook_path: &str, aggregate: &str) -> Result<PersistenceBindings, String> {
    let bluebook_dir = Path::new(bluebook_path).parent();
    let declared = bluebook_dir.map(binds).unwrap_or_default();

    let (authoritative, legacy_mirrors) = match persisted_by(&declared, aggregate)? {
        Some(bindings) => bindings,
        None if declared.is_empty() && !has_hecksagon(bluebook_dir) => {
            (DEFAULT_ADAPTER.to_string(), vec![])
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
    debug_assert!(legacy_mirrors.is_empty());

    let authoritative = Persistence {
        settings: settings_for(bluebook_path, &authoritative),
        adapter: authoritative,
    };

    Ok(PersistenceBindings {
        authoritative,
        mirrors: vec![],
    })
}

fn has_hecksagon(bluebook_dir: Option<&Path>) -> bool {
    bluebook_dir
        .map(|dir| !loading::declarations(dir, "hecksagon").is_empty())
        .unwrap_or(false)
}

fn binds(bluebook_dir: &Path) -> Vec<(String, String, String)> {
    let mut found = Vec::new();
    for source in loading::declarations(bluebook_dir, "hecksagon") {
        let hexagon = hecksagon_parser::parse(&source);

        for binding in hexagon.bindings.iter().filter(|b| b.verb == "persisted_by") {
            found.push((binding.aggregate.clone(), binding.adapter.clone(), binding.role.clone()));
        }
        if let Some(persistence) = hexagon.persistence.clone() {
            found.push((String::new(), persistence, String::new()));
        }
    }
    found
}

pub(crate) fn persisted_by(
    declared: &[(String, String, String)],
    aggregate: &str,
) -> Result<Option<(String, Vec<String>)>, String> {
    let matching: Vec<_> = declared
        .iter()
        .filter(|(named, _, _)| named.rsplit("::").next().unwrap_or(named) == aggregate)
        .collect();
    let matching = if matching.is_empty() {
        declared.iter().filter(|(named, _, _)| named.is_empty()).collect()
    } else {
        matching
    };
    if matching.is_empty() {
        return Ok(None);
    }

    let authoritative: Vec<_> = matching
        .iter()
        .filter(|(_, _, role)| role.is_empty())
        .collect();
    if authoritative.len() != 1 {
        return Err(format!(
            "{aggregate} has {} authoritative persisted_by bindings. Declare exactly one adapter without a role. Mirrors bind separately with mirrored_by.",
            authoritative.len()
        ));
    }
    let roles: Vec<_> = matching.iter().filter(|(_, _, role)| !role.is_empty()).collect();
    if !roles.is_empty() {
        return Err(format!(
            "{aggregate} uses persistence role(s) {}. Persistence is authoritative; use mirrored_by for replicas.",
            roles.iter().map(|(_, _, role)| role.as_str()).collect::<Vec<_>>().join(", ")
        ));
    }
    Ok(Some((
        authoritative[0].1.clone(),
        vec![],
    )))
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
