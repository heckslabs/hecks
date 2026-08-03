//! Deterministic project-wide Bluebook discovery and callable-surface registry.

use crate::bluebook::ir::Domain;
use crate::fqn::{Fqn, Kind};
use crate::naming;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const SKIPPED_DIRECTORIES: &[&str] = &[
    ".git",
    ".bundle",
    "data",
    "node_modules",
    "target",
    "tmp",
    "vendor",
    "generated",
    "coverage",
];

/// A PROJECTION IS PREFERRED, AND NOT PARSED — the same rule `Runtime::
/// boot` already holds itself to (`dispatcher.rs`), applied here because
/// project-wide discovery walks arbitrary `.bluebook` files it cannot
/// know ahead of time are all compiled in. A source with no projection
/// parses when this binary carries a parser ; without one, this refuses
/// by name rather than silently reporting fewer domains than the project
/// actually declares.
#[cfg_attr(feature = "parser", allow(unused_variables))]
fn domain_for(source: &str, source_path: &Path) -> Result<Domain, String> {
    if let Some(domain) = crate::bluebook::projected::by_source(source) {
        return Ok(domain);
    }
    #[cfg(feature = "parser")]
    {
        Ok(crate::bluebook::parser::parse(source))
    }
    #[cfg(not(feature = "parser"))]
    {
        Err(format!(
            "cannot load {}: this binary carries no projection of it, and was built without the parser to read it fresh",
            source_path.display()
        ))
    }
}

#[derive(Clone, Debug)]
pub struct Entry {
    pub fqn: Fqn,
    pub source_directory: PathBuf,
    pub source_path: PathBuf,
    pub declared_verb: String,
    pub domain_version: Option<String>,
    pub domain: Domain,
}

impl Entry {
    pub fn command_p(&self) -> bool {
        self.fqn.kind == Kind::Command
    }
    pub fn query_p(&self) -> bool {
        self.fqn.kind == Kind::Query
    }
}

#[derive(Debug)]
pub struct ProjectLoader {
    pub root: PathBuf,
    pub entries: BTreeMap<String, Entry>,
    /// Every `translations/*.bluebook` edge file discovered beside a
    /// domain's bluebooks — the same glob Ruby's `Folder::DOMAIN_ORDER`
    /// already walks, so a translation a Ruby boot loads is never one a
    /// Rust boot silently cannot see.
    pub translations: Vec<crate::bluebook::translation::ir::Translation>,
}

impl ProjectLoader {
    pub fn load(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref().to_path_buf();
        if !root.is_dir() {
            return Err(format!(
                "project root {} is not a directory",
                root.display()
            ));
        }
        let mut loader = Self {
            root: root.clone(),
            entries: BTreeMap::new(),
            translations: vec![],
        };
        for directory in bluebook_directories(&root)? {
            let worlds = worlds(&directory)?;
            for (source_path, source) in bluebook_sources(&directory)? {
                let domain = domain_for(&source, &source_path)?;
                loader.register(domain, &worlds, &directory, &source_path)?;
            }
            for (_, source) in translation_sources(&directory)? {
                loader
                    .translations
                    .push(crate::bluebook::translation::parser::parse(&source)?);
            }
        }
        Ok(loader)
    }

    pub fn fetch(&self, address: &str) -> Option<&Entry> {
        self.entries.get(address)
    }
    pub fn commands(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values().filter(|entry| entry.command_p())
    }
    pub fn queries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values().filter(|entry| entry.query_p())
    }

    fn register(
        &mut self,
        bluebook: Domain,
        worlds: &[crate::world::ir::World],
        directory: &Path,
        source_path: &Path,
    ) -> Result<(), String> {
        let world = worlds.iter().find(|world| world.name == bluebook.name);
        let realm = world
            .and_then(|world| world.realm.as_deref())
            .ok_or_else(|| {
                format!(
                    "{} in {} has no world realm",
                    bluebook.name,
                    directory.display()
                )
            })?;
        let latest = world.and_then(|world| world.latest.as_deref());
        if let (Some(latest), Some(version)) = (latest, bluebook.version.as_deref()) {
            if latest != version {
                return Err(format!(
                    "{} in {} declares latest {:?}, not {:?}",
                    bluebook.name,
                    directory.display(),
                    latest,
                    version
                ));
            }
        }
        for aggregate in &bluebook.aggregates {
            for command in &aggregate.commands {
                if let Some(version) = bluebook.version.as_deref() {
                    self.add(
                        Fqn::command(
                            Some(realm),
                            &bluebook.name,
                            Some(version),
                            &aggregate.name,
                            &command.name,
                        )?,
                        directory,
                        source_path,
                        &command.name,
                        &bluebook,
                    )?;
                }
                if current(bluebook.version.as_deref(), latest) {
                    self.add(
                        Fqn::command(
                            Some(realm),
                            &bluebook.name,
                            None,
                            &aggregate.name,
                            &command.name,
                        )?,
                        directory,
                        source_path,
                        &command.name,
                        &bluebook,
                    )?;
                }
            }
            for query in &aggregate.queries {
                let name = naming::snake(&query.name);
                if let Some(version) = bluebook.version.as_deref() {
                    self.add(
                        Fqn::query(
                            Some(realm),
                            &bluebook.name,
                            Some(version),
                            &aggregate.name,
                            &name,
                        )?,
                        directory,
                        source_path,
                        &query.name,
                        &bluebook,
                    )?;
                }
                if current(bluebook.version.as_deref(), latest) {
                    self.add(
                        Fqn::query(Some(realm), &bluebook.name, None, &aggregate.name, &name)?,
                        directory,
                        source_path,
                        &query.name,
                        &bluebook,
                    )?;
                }
            }
        }
        Ok(())
    }

    fn add(
        &mut self,
        fqn: Fqn,
        directory: &Path,
        source_path: &Path,
        declared_verb: &str,
        domain: &Domain,
    ) -> Result<(), String> {
        let address = fqn.to_string();
        if let Some(existing) = self.entries.get(&address) {
            return Err(format!(
                "{address} is declared in both {} and {}",
                existing.source_directory.display(),
                directory.display()
            ));
        }
        self.entries.insert(
            address,
            Entry {
                fqn,
                source_directory: directory.to_path_buf(),
                source_path: source_path.to_path_buf(),
                declared_verb: declared_verb.to_string(),
                domain_version: domain.version.clone(),
                domain: domain.clone(),
            },
        );
        Ok(())
    }
}

fn current(version: Option<&str>, latest: Option<&str>) -> bool {
    version.is_none() || version == latest
}

fn bluebook_directories(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut found = vec![];
    walk(root, &mut found)?;
    found.sort();
    Ok(found)
}

fn walk(directory: &Path, found: &mut Vec<PathBuf>) -> Result<(), String> {
    let mut entries: Vec<PathBuf> = fs::read_dir(directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect();
    entries.sort();
    for path in entries {
        if !path.is_dir() {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if SKIPPED_DIRECTORIES.contains(&name) {
            continue;
        }
        if name == "bluebook" && has_bluebook(&path) {
            found.push(path.clone());
        }
        walk(&path, found)?;
    }
    Ok(())
}

fn has_bluebook(directory: &Path) -> bool {
    fs::read_dir(directory)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "bluebook")
        })
}

/// `<bluebook dir>/translations/*.bluebook`, sorted — the edge files a
/// domain's shape changes are declared in. Ruby's loader has globbed
/// this folder since the language landed; without the same walk here, a
/// file Ruby refuses to boot on would simply not exist to Rust.
pub fn translation_sources(directory: &Path) -> Result<Vec<(PathBuf, String)>, String> {
    let translations = directory.join("translations");
    if !translations.is_dir() {
        return Ok(vec![]);
    }
    let mut paths: Vec<PathBuf> = fs::read_dir(&translations)
        .map_err(|error| format!("cannot read {}: {error}", translations.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "bluebook")
        })
        .collect();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            fs::read_to_string(&path)
                .map(|source| (path.clone(), source))
                .map_err(|error| format!("cannot read {}: {error}", path.display()))
        })
        .collect()
}

fn bluebook_sources(directory: &Path) -> Result<Vec<(PathBuf, String)>, String> {
    let mut paths: Vec<PathBuf> = fs::read_dir(directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "bluebook")
        })
        .collect();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            fs::read_to_string(&path)
                .map(|source| (path.clone(), source))
                .map_err(|error| format!("cannot read {}: {error}", path.display()))
        })
        .collect()
}

fn worlds(directory: &Path) -> Result<Vec<crate::world::ir::World>, String> {
    let mut paths: Vec<PathBuf> = fs::read_dir(directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "world")
        })
        .collect();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            fs::read_to_string(&path)
                .map(|source| crate::world::parser::parse(&source))
                .map_err(|error| format!("cannot read {}: {error}", path.display()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovers_commands_and_snake_case_queries() {
        let root = temporary_project("catalog");
        write_bluebook(
            &root,
            "catalog",
            r#"
Hecks.bluebook "Catalog" do
  aggregate "Book" do
    command "Add" do
    end
    query "Available" do
    end
  end
end
"#,
        );
        write_world(&root, "catalog", "Catalog", None);
        write_bluebook(
            &root,
            "billing",
            r#"
Hecks.bluebook "Billing" do
  aggregate "Invoice" do
    command "Issue" do
    end
  end
end
"#,
        );
        write_world(&root, "billing", "Billing", None);

        let loader = ProjectLoader::load(&root).unwrap();
        assert_eq!(
            loader.entries.keys().cloned().collect::<Vec<_>>(),
            vec![
                "Acme::Billing::Invoice.Issue",
                "Acme::Catalog::Book.Add",
                "Acme::Catalog::Book.available",
            ]
        );
        assert!(loader
            .fetch("Acme::Catalog::Book.available")
            .unwrap()
            .query_p());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refuses_duplicate_addresses() {
        let root = temporary_project("duplicates");
        for name in ["one", "two"] {
            write_bluebook(
                &root,
                name,
                r#"
Hecks.bluebook "Catalog" do
  aggregate "Book" do
    command "Add" do
    end
  end
end
"#,
            );
            write_world(&root, name, "Catalog", None);
        }
        let error = ProjectLoader::load(&root).unwrap_err();
        assert!(error.contains("Acme::Catalog::Book.Add"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pins_every_version_and_assigns_the_unpinned_alias_to_latest() {
        let root = temporary_project("versions");
        for version in ["v1", "v2"] {
            write_bluebook(
                &root,
                &format!("banking_{version}"),
                &format!(
                    r#"
Hecks.bluebook "Banking", version: "{version}" do
  aggregate "Account" do
    command "Credit" do
    end
  end
end
"#
                ),
            );
            write_world(
                &root,
                &format!("banking_{version}"),
                "Banking",
                if version == "v2" { Some("v2") } else { None },
            );
        }
        let loader = ProjectLoader::load(&root).unwrap();
        assert_eq!(
            loader.entries.keys().cloned().collect::<Vec<_>>(),
            vec![
                "Acme::Banking::Account.Credit",
                "Acme::Banking@v1::Account.Credit",
                "Acme::Banking@v2::Account.Credit",
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }

    /// The glob Ruby's `Folder::DOMAIN_ORDER` has walked since the
    /// translation language landed — a translation Ruby loads at boot
    /// must never be one Rust silently cannot see, and a malformed edge
    /// file must refuse the load, not vanish from it.
    #[test]
    fn discovers_translation_edges_beside_a_domain_s_bluebooks() {
        let root = temporary_project("translations");
        write_bluebook(
            &root,
            "catalog",
            r#"
Hecks.bluebook "Catalog" do
  aggregate "Book" do
    command "Add" do
    end
  end
end
"#,
        );
        write_world(&root, "catalog", "Catalog", None);
        let translations = root.join("catalog").join("bluebook").join("translations");
        fs::create_dir_all(&translations).unwrap();
        fs::write(
            translations.join("2-b81d04.bluebook"),
            "Hecks.data_translation \"Catalog\", from: \"a3f9c2\", to: \"b81d04\" do\n  aggregate \"Book\" do\n    rename :cost, to: :amount\n  end\nend\n",
        )
        .unwrap();

        let loader = ProjectLoader::load(&root).unwrap();
        assert_eq!(loader.translations.len(), 1);
        assert_eq!(loader.translations[0].domain, "Catalog");
        assert_eq!(loader.translations[0].for_aggregate("Book").unwrap().renames, vec![("cost".to_string(), "amount".to_string())]);

        fs::write(
            translations.join("3-broken.bluebook"),
            "Hecks.data_translation \"Catalog\", from: \"b81d04\", to: \"c92e15\" do\n  aggregate \"Book\" do\n    rename :cost\n  end\nend\n",
        )
        .unwrap();
        let error = ProjectLoader::load(&root).unwrap_err();
        assert_eq!(error, "a rename needs a destination name (to:)");

        fs::remove_dir_all(root).unwrap();
    }

    fn temporary_project(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "hecksagain-project-loader-{label}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_bluebook(root: &Path, name: &str, source: &str) {
        let directory = root.join(name).join("bluebook");
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join(format!("{name}.bluebook")), source).unwrap();
    }

    fn write_world(root: &Path, name: &str, domain: &str, latest: Option<&str>) {
        let directory = root.join(name).join("bluebook");
        let latest = latest
            .map(|version| format!("  latest \"{version}\"\n"))
            .unwrap_or_default();
        fs::write(
            directory.join(format!("{name}.world")),
            format!("Hecks.world \"{domain}\" do\n  realm \"Acme\"\n{latest}end\n"),
        )
        .unwrap();
    }
}
