//! World IR — Rust mirror of Hecksagon::Structure::World for .world files.
//!
//! [antibody-exempt: rust/src/world/ir.rs — kernel-floor .world IR : the Rust
//!  mirror of the .world grammar's parsed form, sibling to world/attach.rs
//!  (already exempt). Host-side config types, not bluebookable domain. i728
//!  added the dormant persistence_strict() reader.]
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
    /// `realm "name"` — the top-level namespace ABOVE domain. When declared,
    /// the heki store nests under `<dir>/<realm>/<domain>/<aggregate>.heki`.
    /// Absent realm keeps the legacy `<dir>/<domain>/<aggregate>` path, so
    /// adding realm to a world is purely additive (presence is the switch).
    pub realm: Option<String>,
    /// `concern "Name" do; description "..." end` entries.
    pub concerns: Vec<Concern>,
    /// Extension config blocks — one entry per `extension_name do ... end`
    /// (heki, ollama, sqlite, claude, websocket, static_assets, ...).
    /// Order preserved from source.
    pub configs: Vec<ExtensionConfig>,
    /// MCP server declarations from the `mcp do; server :name do; ... end end`
    /// block (i610). Each names a server the runtime resolves at dispatch
    /// time plus the environment variable its auth token is read from.
    /// Order preserved from source.
    pub servers: Vec<McpServer>,
    /// Sprint 14 world-wires-real-adapters — top-level
    /// `adapter "Name" do; <key> <value>; ... end` entries. Each binds a
    /// driven-adapter (declared by name in a .hecksagon) to its real
    /// backend in this deployment. Presence of the binding IS the signal :
    /// when the driven_adapter_resolver finds an entry with this name, it
    /// uses the binding's values as the wrapped-call return instead of
    /// the canned default ; absent, it falls back to canned. No `backend:`
    /// flag — the values themselves carry the per-deployment config
    /// (URL, env-var, output overrides, etc.).
    pub adapter_bindings: Vec<AdapterBinding>,
}

/// `server :name do; token_env "ENV_VAR" end` inside an `mcp do ... end`
/// block (i610). Declares one MCP server's connection details: its name —
/// the symbol an `adapter :mcp, server: :name` binding references — and the
/// environment variable the runtime reads the auth token from at dispatch.
#[derive(Debug, Default, Clone)]
pub struct McpServer {
    /// Server symbol the `adapter :mcp, server: :x` binding names (`gmail`).
    pub name: String,
    /// Environment variable the auth token is read from at dispatch time.
    pub token_env: Option<String>,
}

/// `concern "Name" do; description "..." end`.
#[derive(Debug, Default, Clone)]
pub struct Concern {
    pub name: String,
    pub description: Option<String>,
}

/// Sprint 14 world-wires-real-adapters — a top-level
/// `adapter "Name" do; <key> <value>; ... end` entry inside a `.world`
/// file. Binds a driven-adapter (declared by name in a `.hecksagon`)
/// to its real backend for this deployment. Values keep the same
/// source-token form used by ExtensionConfig so `build_attr_map` in
/// the resolver can apply the same conversion rule.
#[derive(Debug, Default, Clone)]
pub struct AdapterBinding {
    /// Adapter name as quoted in the `.hecksagon` declaration. The
    /// resolver matches a driven-adapter against this name verbatim.
    pub name: String,
    /// Ordered key/value pairs declared inside the binding block.
    /// Merged onto the follow-on dispatch's attrs at fire time.
    pub values: Vec<(String, String)>,
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

    /// i728 DORMANT strict flag — `persistence do strict true end` in a
    /// `.world` marks the deployment STRICT : in Phase C an unwired domain
    /// becomes a BOOT ERROR rather than defaulting to memory. Parsed
    /// generically as a `persistence` extension block ; this reader is the
    /// only consumer and is NOT yet wired into boot enforcement (the Phase A
    /// keystone is additive — the flag exists but changes no behaviour yet).
    pub fn persistence_strict(&self) -> bool {
        self.config_for("persistence").and_then(|c| c.get("strict")) == Some("true")
    }

    /// Client-door posture — `door do posture "governed" end` in a `.world`
    /// declares the HTTP serve door GOVERNED for this deployment (per-request
    /// bearer principals, fail-closed without one, introspection closed).
    /// Absent block = open (today's behavior). Read from the SERVED root's
    /// own `.world` only — see `attach::door_posture_for_root` for why the
    /// sibling-union walk must never decide the door.
    pub fn door_posture(&self) -> Option<&str> {
        self.config_for("door").and_then(|c| c.get("posture"))
    }

    /// Look up an MCP server declaration by name (i610). Trims a leading
    /// `:` so both `:gmail` and `gmail` answer — same rule the dispatcher's
    /// `resolve_server_spawn` follows for the `server` adapter field.
    pub fn server_for(&self, name: &str) -> Option<&McpServer> {
        let want = name.trim_start_matches(':');
        self.servers.iter().find(|s| s.name == want)
    }

    /// Sprint 14 world-wires-real-adapters — look up an adapter binding
    /// by name. The driven-adapter resolver calls this for each handler ;
    /// `Some(binding)` means "use binding.values as the wrapped-call
    /// return", `None` means "fall back to the canned default". Names
    /// match the quoted name from the `.hecksagon`'s
    /// `adapter "Name" do ...` declaration verbatim.
    pub fn adapter_binding_for(&self, name: &str) -> Option<&AdapterBinding> {
        self.adapter_bindings.iter().find(|b| b.name == name)
    }
}

impl AdapterBinding {
    /// Look up a value by key within this binding. Mirrors
    /// `ExtensionConfig::get` so consumers can probe binding values the
    /// same way they probe extension config values.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

impl ExtensionConfig {
    /// Look up a value by key within this block.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}
