//! World IR — Rust mirror of Hecksagon::Structure::World for .world files.
//!
//! A .world declares runtime configuration — extension options, heki data
//! location, strategic descriptors — that sits alongside the .bluebook
//! (domain definition) and .hecksagon (wiring) files.
//!
//! Two families of .world file exist in-tree today:
//!
//!   Family A — runtime/extension config (miette.world, hecks_appeal.world):
//!
//! ```text
//! Hecks.world "Miette" do
//!   heki   do; dir "information" end
//!   ollama do; model "bluebook-architect"; url "http://..." end
//! end
//! ```
//!
//!   Family B — strategic descriptors (nursery/*.world):
//!
//! ```text
//! Hecks.world "DomainConception" do
//!   purpose "..."
//!   vision  "..."
//!   concern "CompletenessAtBirth" do; description "..." end
//! end
//! ```
//!
//! The IR carries both shapes so a single parser covers the lot.

/// A .world file parsed into IR.
#[derive(Debug, Default, Clone)]
pub struct World {
    /// Declared inside `Hecks.world "Name" do`.
    pub name: String,
    /// `purpose "..."` — strategic intent, one-liner.
    pub purpose: Option<String>,
    /// `vision "..."` — longer-horizon direction.
    pub vision: Option<String>,
    /// `audience "..."` — who the world is for.
    pub audience: Option<String>,
    /// `concern "Name" do; description "..." end` entries.
    pub concerns: Vec<Concern>,
    /// Extension config blocks — one entry per `extension_name do ... end`
    /// (heki, ollama, sqlite, claude, websocket, static_assets, ...).
    /// Order preserved from source.
    pub configs: Vec<ExtensionConfig>,
}

/// `concern "Name" do; description "..." end`.
#[derive(Debug, Default, Clone)]
pub struct Concern {
    pub name: String,
    pub description: Option<String>,
}

/// `ext_name do; key value; ... end` — a single extension config block.
#[derive(Debug, Default, Clone)]
pub struct ExtensionConfig {
    /// Block name: `heki`, `ollama`, `sqlite`, `claude`, ...
    pub name: String,
    /// Ordered key/value pairs. Values are stored as their source tokens
    /// (quoted strings have their quotes stripped; ints/floats/bools stay
    /// as their textual form; string arrays are stored as JSON-ish text).
    pub values: Vec<(String, String)>,
}

impl World {
    /// Look up an extension config block by name.
    pub fn config_for(&self, name: &str) -> Option<&ExtensionConfig> {
        self.configs.iter().find(|c| c.name == name)
    }
}

impl ExtensionConfig {
    /// Look up a value by key within this block.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}
