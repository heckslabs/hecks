//! Project-wide command/query routing for discovered Bluebooks.

use crate::bluebook::project_loader::{Entry, ProjectLoader};
use crate::fqn::{Fqn, Kind};
use crate::interp_expr::State;
use crate::runtime::dispatcher::Runtime;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

/// Routes public realm FQNs while retaining one runtime per discovered domain
/// version. Exact and unpinned/latest aliases therefore share their state.
pub struct Router {
    pub register: ProjectLoader,
    runtimes: BTreeMap<String, Runtime>,
    shortcuts: BTreeMap<String, Vec<Entry>>,
}

impl Router {
    pub fn load(root: impl AsRef<std::path::Path>) -> Result<Self, String> {
        let register = ProjectLoader::load(root)?;
        let mut runtimes = BTreeMap::new();
        let mut shortcuts: BTreeMap<String, Vec<Entry>> = BTreeMap::new();
        for entry in register.entries.values() {
            let key = runtime_key(entry);
            if !runtimes.contains_key(&key) {
                runtimes.insert(key, Runtime::boot(&entry.source_path)?);
            }
            if entry.fqn.version.is_none() {
                shortcuts
                    .entry(shortcut_key(entry))
                    .or_default()
                    .push(entry.clone());
            }
        }
        Ok(Self {
            register,
            runtimes,
            shortcuts,
        })
    }

    pub fn resolve(&self, address: &str) -> Result<&Entry, String> {
        let fqn = Fqn::parse(address)?;
        if fqn.realm.is_none() {
            return Err(format!("router addresses require a realm: {address:?}"));
        }
        self.register
            .fetch(&fqn.to_string())
            .ok_or_else(|| format!("no Bluebook route for {address:?}"))
    }

    pub fn dispatch(&mut self, address: &str, args: &State) -> Result<State, String> {
        let entry = self.resolve(address)?.clone();
        if entry.fqn.kind != Kind::Command {
            return Err(format!("{address:?} names a query; use Router::query"));
        }
        self.runtimes
            .get_mut(&runtime_key(&entry))
            .expect("registered runtime")
            .dispatch(&local_verb(&entry), args)
    }

    pub fn query(&mut self, address: &str, args: &State) -> Result<Vec<Value>, String> {
        let entry = self.resolve(address)?.clone();
        if entry.fqn.kind != Kind::Query {
            return Err(format!("{address:?} names a command; use Router::dispatch"));
        }
        self.runtimes
            .get_mut(&runtime_key(&entry))
            .expect("registered runtime")
            .query(&local_verb(&entry), args)
    }

    pub fn dispatch_short(&mut self, address: &str, args: &State) -> Result<State, String> {
        let entry = self.resolve_short(address)?;
        if entry.fqn.kind != Kind::Command {
            return Err(format!(
                "{address:?} names a query; use Router::query_short"
            ));
        }
        self.runtimes
            .get_mut(&runtime_key(&entry))
            .expect("registered runtime")
            .dispatch(&local_verb(&entry), args)
    }

    pub fn query_short(&mut self, address: &str, args: &State) -> Result<Vec<Value>, String> {
        let entry = self.resolve_short(address)?;
        if entry.fqn.kind != Kind::Query {
            return Err(format!(
                "{address:?} names a command; use Router::dispatch_short"
            ));
        }
        self.runtimes
            .get_mut(&runtime_key(&entry))
            .expect("registered runtime")
            .query(&local_verb(&entry), args)
    }

    fn resolve_short(&self, address: &str) -> Result<Entry, String> {
        let candidates = self
            .shortcuts
            .get(address)
            .ok_or_else(|| format!("no Bluebook shortcut for {address:?}"))?;
        if candidates.len() > 1 {
            let shown = candidates
                .iter()
                .map(|entry| entry.fqn.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(format!("{address} is ambiguous — choose one of: {shown}"));
        }
        Ok(candidates[0].clone())
    }
}

// The ordinary application surface is a process-wide router. Keeping
// `Router` public as well gives embedded hosts and tests an explicit,
// independently-owned alternative.
static DEFAULT_ROUTER: OnceLock<Mutex<Option<Router>>> = OnceLock::new();

fn default_router() -> &'static Mutex<Option<Router>> {
    DEFAULT_ROUTER.get_or_init(|| Mutex::new(None))
}

/// Discover and boot a project as this process's default router.
pub fn boot(root: impl AsRef<std::path::Path>) -> Result<(), String> {
    let router = Router::load(root)?;
    *default_router()
        .lock()
        .map_err(|_| "default router lock is poisoned".to_string())? = Some(router);
    Ok(())
}

/// Dispatch through the process's default router.
pub fn dispatch(address: &str, args: &State) -> Result<State, String> {
    default_router()
        .lock()
        .map_err(|_| "default router lock is poisoned".to_string())?
        .as_mut()
        .ok_or_else(|| {
            "no default router is booted — call storehouse::boot(root) first".to_string()
        })?
        .dispatch(address, args)
}

/// Query through the process's default router.
pub fn query(address: &str, args: &State) -> Result<Vec<Value>, String> {
    default_router()
        .lock()
        .map_err(|_| "default router lock is poisoned".to_string())?
        .as_mut()
        .ok_or_else(|| {
            "no default router is booted — call storehouse::boot(root) first".to_string()
        })?
        .query(address, args)
}

pub fn dispatch_short(address: &str, args: &State) -> Result<State, String> {
    default_router()
        .lock()
        .map_err(|_| "default router lock is poisoned".to_string())?
        .as_mut()
        .ok_or_else(|| {
            "no default router is booted — call storehouse::boot(root) first".to_string()
        })?
        .dispatch_short(address, args)
}

pub fn query_short(address: &str, args: &State) -> Result<Vec<Value>, String> {
    default_router()
        .lock()
        .map_err(|_| "default router lock is poisoned".to_string())?
        .as_mut()
        .ok_or_else(|| {
            "no default router is booted — call storehouse::boot(root) first".to_string()
        })?
        .query_short(address, args)
}

/// Convert a Rust-looking path used by the sugar macros into the public FQN.
/// `Examples::Banking::Account::Open` becomes
/// `Examples::Banking::Account.Open`.
pub fn fqn_from_rust_path(path: &str) -> Result<String, String> {
    let (head, verb) = path.rsplit_once("::").ok_or_else(|| {
        format!("command path needs Realm::Domain::Aggregate::Verb — got {path:?}")
    })?;
    if head.is_empty() || verb.is_empty() {
        return Err(format!(
            "command path needs Realm::Domain::Aggregate::Verb — got {path:?}"
        ));
    }
    Ok(format!("{head}.{verb}"))
}

/// Apply an explicit domain version to a Rust-looking command/query path.
pub fn fqn_from_rust_path_with_version(path: &str, version: &str) -> Result<String, String> {
    let fqn = Fqn::parse(&fqn_from_rust_path(path)?)?;
    match fqn.kind {
        Kind::Command => Fqn::command(
            fqn.realm.as_deref(),
            &fqn.domain,
            Some(version),
            &fqn.aggregate,
            &fqn.verb,
        ),
        Kind::Query => Fqn::query(
            fqn.realm.as_deref(),
            &fqn.domain,
            Some(version),
            &fqn.aggregate,
            &fqn.verb,
        ),
    }
    .map(|fqn| fqn.to_string())
}

/// Dispatch an FQN written as a Rust path through the default router.
pub fn dispatch_rust_path(path: &str, args: &State) -> Result<State, String> {
    let address = fqn_from_rust_path(path)?;
    if address.contains("::") {
        dispatch(&address, args)
    } else {
        dispatch_short(&address, args)
    }
}

/// Query an FQN written as a Rust path through the default router.
pub fn query_rust_path(path: &str, args: &State) -> Result<Vec<Value>, String> {
    let address = fqn_from_rust_path(path)?;
    if address.contains("::") {
        query(&address, args)
    } else {
        query_short(&address, args)
    }
}

pub fn dispatch_rust_path_with_version(
    path: &str,
    version: &str,
    args: &State,
) -> Result<State, String> {
    dispatch(&fqn_from_rust_path_with_version(path, version)?, args)
}

pub fn query_rust_path_with_version(
    path: &str,
    version: &str,
    args: &State,
) -> Result<Vec<Value>, String> {
    query(&fqn_from_rust_path_with_version(path, version)?, args)
}

fn runtime_key(entry: &Entry) -> String {
    format!(
        "{}::{}@{}",
        entry.source_directory.display(),
        entry.fqn.domain,
        entry.domain_version.as_deref().unwrap_or("unversioned")
    )
}

fn shortcut_key(entry: &Entry) -> String {
    format!("{}.{}", entry.fqn.aggregate, entry.fqn.verb)
}

fn local_verb(entry: &Entry) -> String {
    format!(
        "{}::{}.{}",
        entry.fqn.domain, entry.fqn.aggregate, entry.declared_verb
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use serde_json::Map;
    use std::fs;
    use std::path::{Path, PathBuf};

    /// THE DEFAULT ROUTER IS PROCESS-GLOBAL, so the tests that boot it cannot run
    /// at once. `boot` REPLACES it, and whichever booted last would then answer
    /// for all of them — the others would dispatch against a domain they never
    /// wrote. Rust runs a binary's tests in parallel, so they take turns here
    /// rather than hoping the scheduler interleaves kindly.
    ///
    /// Caught by a single failure in one `--workspace` run and not reproducible
    /// after: `macro_options_pin_a_version_without_claiming_a_payload_key` looked
    /// for a command another test's router had replaced. Poisoning is absorbed
    /// so one genuine failure does not cascade into two more.
    static BOOTED_ROUTER: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn booting() -> std::sync::MutexGuard<'static, ()> {
        BOOTED_ROUTER.lock().unwrap_or_else(|held| held.into_inner())
    }

    #[test]
    fn routes_every_discovered_domain_and_translates_query_names() {
        let root = temporary_project("all-domains");
        write_domain(
            &root,
            "catalog",
            "Catalog",
            r#"
  aggregate "Book" do
    attribute :code, String
    identified_by { code }
    command "Add" do
      attribute :code, String
    end
    query "Available" do
    end
  end
"#,
            None,
            None,
        );
        write_domain(
            &root,
            "billing",
            "Billing",
            r#"
  aggregate "Invoice" do
    attribute :number, String
    identified_by { number }
    command "Issue" do
      attribute :number, String
    end
  end
"#,
            None,
            None,
        );

        let mut router = Router::load(&root).unwrap();
        let book = Map::from_iter([(String::from("code"), json!("book-1"))]);
        assert_eq!(
            router
                .dispatch("Acme::Catalog::Book.Add", &book)
                .unwrap()
                .get("code"),
            Some(&json!("book-1"))
        );
        assert_eq!(
            router
                .query("Acme::Catalog::Book.available", &Map::new())
                .unwrap()
                .len(),
            1
        );
        let invoice = Map::from_iter([(String::from("number"), json!("invoice-1"))]);
        assert_eq!(
            router
                .dispatch("Acme::Billing::Invoice.Issue", &invoice)
                .unwrap()
                .get("number"),
            Some(&json!("invoice-1"))
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resolves_unpinned_routes_to_latest_version() {
        let root = temporary_project("versions");
        write_domain(
            &root,
            "banking-v1",
            "Banking",
            "  aggregate \"Account\" do\n    command \"Credit\" do\n    end\n  end\n",
            Some("v1"),
            None,
        );
        write_domain(
            &root,
            "banking-v2",
            "Banking",
            "  aggregate \"Account\" do\n    command \"Credit\" do\n    end\n  end\n",
            Some("v2"),
            Some("v2"),
        );
        let router = Router::load(&root).unwrap();
        assert_eq!(
            router
                .resolve("Acme::Banking::Account.Credit")
                .unwrap()
                .domain_version
                .as_deref(),
            Some("v2")
        );
        assert_eq!(
            router
                .resolve("Acme::Banking@v1::Account.Credit")
                .unwrap()
                .domain_version
                .as_deref(),
            Some("v1")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn default_router_and_sugar_macros_need_neither_a_router_nor_json_maps() {
        let root = temporary_project("default-router");
        write_domain(
            &root,
            "catalog",
            "Catalog",
            r#"
  aggregate "Book" do
    attribute :code, String
    identified_by { code }
    command "Add" do
      attribute :code, String
    end
    query "Available" do
    end
  end
"#,
            None,
            None,
        );

        let _serialised = booting();
        boot(&root).unwrap();
        let state = crate::command!(Acme::Catalog::Book::Add, { code: "book-1" }).unwrap();
        assert_eq!(state.get("code"), Some(&json!("book-1")));
        assert_eq!(
            crate::query!(Acme::Catalog::Book::available, {})
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            crate::command!(Book::Add, { code: "book-2" })
                .unwrap()
                .get("code"),
            Some(&json!("book-2"))
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn macro_options_pin_a_version_without_claiming_a_payload_key() {
        let root = temporary_project("macro-options");
        write_domain(
            &root,
            "banking-v1",
            "Banking",
            r#"
  aggregate "Account" do
    attribute :code, String
    identified_by { code }
    command "LegacyOpen" do
      attribute :code, String
    end
  end
"#,
            Some("v1"),
            None,
        );
        write_domain(
            &root,
            "banking-v2",
            "Banking",
            r#"
  aggregate "Account" do
    attribute :code, String
    identified_by { code }
    command "Open" do
      attribute :code, String
    end
  end
"#,
            Some("v2"),
            Some("v2"),
        );

        let _serialised = booting();
        boot(&root).unwrap();
        assert_eq!(
            crate::command!(Acme::Banking::Account::Open, { code: "latest" })
                .unwrap()
                .get("code"),
            Some(&json!("latest"))
        );
        assert_eq!(
            crate::command!(options(version: "v1"), Acme::Banking::Account::LegacyOpen, { code: "legacy" })
                .unwrap()
                .get("code"),
            Some(&json!("legacy"))
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn short_macro_routes_when_unique_and_refuses_when_ambiguous() {
        let root = temporary_project("shortcuts");
        for (directory, domain) in [("catalog", "Catalog"), ("billing", "Billing")] {
            write_domain(
                &root,
                directory,
                domain,
                r#"
  aggregate "SharedBook" do
    command "Add" do
    end
  end
"#,
                None,
                None,
            );
        }

        let _serialised = booting();
        boot(&root).unwrap();
        let error = crate::command!(SharedBook::Add, {}).unwrap_err();
        assert!(error.contains("SharedBook.Add is ambiguous"));
        assert!(error.contains("Acme::Billing::SharedBook.Add"));
        assert!(error.contains("Acme::Catalog::SharedBook.Add"));
        fs::remove_dir_all(root).unwrap();
    }

    fn temporary_project(label: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("hecksagain-router-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_domain(
        root: &Path,
        directory_name: &str,
        domain: &str,
        body: &str,
        version: Option<&str>,
        latest: Option<&str>,
    ) {
        let directory = root.join(directory_name).join("bluebook");
        fs::create_dir_all(&directory).unwrap();
        let version = version
            .map(|v| format!(", version: \"{v}\""))
            .unwrap_or_default();
        fs::write(
            directory.join(format!("{directory_name}.bluebook")),
            format!("Hecks.bluebook \"{domain}\"{version} do\n{body}end\n"),
        )
        .unwrap();
        let latest = latest
            .map(|v| format!("  latest \"{v}\"\n"))
            .unwrap_or_default();
        fs::write(
            directory.join(format!("{directory_name}.world")),
            format!("Hecks.world \"{domain}\" do\n  realm \"Acme\"\n{latest}end\n"),
        )
        .unwrap();
    }
}
