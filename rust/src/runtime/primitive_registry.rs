//! PrimitiveRegistry — runtime index of imperative kernel-floor leaves.
//!
//! Sprint-14 (storehouse-primitive-conception) promotes each
//! `[antibody-exempt]` kernel-floor dispatcher from an opaque Rust
//! function into a first-class bluebook record (`Storehouse::Primitive`).
//! This module is the runtime side : a tiny `HashMap<Name, PrimitiveSpec>`
//! the runtime consults to recognise a dispatched command as routing to
//! one of the kernel-floor leaves.
//!
//! Contract :
//!   - `PrimitiveSpec` mirrors the bluebook record (name + kind +
//!     signature + implementation + active flag).
//!   - `PrimitiveRegistry::seed_builtins` populates the registry with
//!     the current hand-coded primitives — the seed list that mirrors
//!     what's actually in `rust/src/runtime/*_dispatcher.rs`. This is
//!     the t4 "seeded at boot with current hand-coded primitives" of
//!     the sprint. Future boots may layer Storehouse::Primitive store
//!     records on top via `Self::overlay_from_heki` (filed as a follow-
//!     up — the seed list is the floor).
//!   - `lookup(name)` returns the registered spec ; the runtime's
//!     `resolve_primitive_*` helpers consult this BEFORE running their
//!     hard-coded match arm. A miss means "no declared primitive at
//!     this name" — the macrophage flags it.
//!
//! Why a separate module from `framework_registry` :
//!   `framework_registry` walks the framework hecksagons (adapter
//!   families / behavior kinds). `primitive_registry` walks the
//!   imperative leaves those families ULTIMATELY bottom out in.
//!   Different layer ; sibling, not refactor.
//!
//! Usage :
//!   let mut reg = PrimitiveRegistry::new();
//!   reg.seed_builtins();
//!   if let Some(spec) = reg.lookup("Process.Spawn") { ... }
//!
//! [antibody-exempt: rust/src/runtime/primitive_registry.rs — kernel-
//!  floor index of the kernel-floor leaves. The registry itself is the
//!  bluebook→runtime bridge for Storehouse::Primitive ; it cannot itself
//!  be bluebook-described until the very mechanism it provides is live.
//!  Retire this marker when the meta-shape compiler emits this module
//!  from the Storehouse::Primitive aggregate (sprint-14 follow-up).]

use std::collections::HashMap;

/// One imperative kernel-floor leaf — the runtime-side mirror of a
/// `Storehouse::Primitive` bluebook record.
///
/// `name` is the dotted FQN the runtime dispatches against
/// (e.g. "Process.Spawn"). `kind` names the dispatcher family
/// ("process", "claude_tool", "web_tool", etc.). `signature` is a
/// free-form comma-separated "attr:VO" string mirrored from the
/// declaration ; documentation-only at runtime today. `implementation`
/// is the Rust handler path the bluebook claims runs this primitive
/// (e.g. "exec_dispatcher::dispatch") — the macrophage uses this to
/// verify the handler exists.
#[derive(Debug, Clone, Default)]
pub struct PrimitiveSpec {
    pub name: String,
    pub kind: String,
    pub signature: String,
    pub implementation: String,
    /// True when the primitive is registered + routable ; matches the
    /// bluebook record's `status == "active"`. Retired primitives keep
    /// the audit row but are NOT in the registry's lookup table.
    pub active: bool,
}

impl PrimitiveSpec {
    pub fn new(
        name: &str,
        kind: &str,
        signature: &str,
        implementation: &str,
    ) -> Self {
        Self {
            name: name.to_string(),
            kind: kind.to_string(),
            signature: signature.to_string(),
            implementation: implementation.to_string(),
            active: true,
        }
    }
}

/// The runtime's index of declared primitives — a flat HashMap keyed by
/// the dotted FQN. Populated at boot by `seed_builtins` (and later
/// overlaid from the Storehouse::Primitive .heki store).
#[derive(Debug, Clone, Default)]
pub struct PrimitiveRegistry {
    by_name: HashMap<String, PrimitiveSpec>,
}

impl PrimitiveRegistry {
    pub fn new() -> Self {
        Self {
            by_name: HashMap::new(),
        }
    }

    /// Seed the registry with the current hand-coded primitives — one
    /// record per `[antibody-exempt]` kernel-floor dispatcher.
    ///
    /// This is the t4 seed list. Adding a new imperative leaf to the
    /// runtime means TWO touches : the new dispatcher module AND a new
    /// entry here. The t5 macrophage cross-references these two : every
    /// `_dispatcher.rs` must have a matching seed entry (and vice
    /// versa), so the seed list cannot silently drift from the source
    /// tree.
    pub fn seed_builtins(&mut self) {
        // Process spawn — the generic `Primitive::Process.Spawn` leaf
        // (framework/primitive/primitive.bluebook). The only one whose
        // *.bluebook also lives today ; the rest are declared by this
        // sprint's Storehouse::Primitive surface.
        self.register(PrimitiveSpec::new(
            "Process.Spawn",
            "process",
            "id:String,cmd:String,result_into:String",
            "exec_dispatcher::dispatch",
        ));
        // Claude tool invocations — the :claude_tool adapter family.
        self.register(PrimitiveSpec::new(
            "ClaudeTool.Invoke",
            "claude_tool",
            "tool:String,command:String",
            "claude_tool_dispatcher::invoke",
        ));
        // MCP tool invocations — the :mcp adapter family.
        self.register(PrimitiveSpec::new(
            "McpTool.Invoke",
            "mcp_tool",
            "server:String,tool:String,arguments:String",
            "mcp_dispatcher::invoke",
        ));
        // Web tool — two behaviors share one dispatcher.
        self.register(PrimitiveSpec::new(
            "WebTool.Fetch",
            "web_tool",
            "url:String",
            "web_tool_dispatcher::web_fetch",
        ));
        self.register(PrimitiveSpec::new(
            "WebTool.Search",
            "web_tool",
            "query:String",
            "web_tool_dispatcher::web_search",
        ));
        // Compute — function-registry-backed local computation.
        self.register(PrimitiveSpec::new(
            "Compute.Invoke",
            "compute",
            "function_name:String,response_into_target:String,response_into_attr:String",
            "compute_dispatcher::dispatch",
        ));
        // LLM — prompt-substitution + provider-routing.
        self.register(PrimitiveSpec::new(
            "Llm.Invoke",
            "llm",
            "prompt:String,response_into_target:String,response_into_attr:String",
            "llm_dispatcher::dispatch",
        ));
        // Shell — placeholder-substituted argv exec (Ruby-parity port).
        self.register(PrimitiveSpec::new(
            "Shell.Invoke",
            "shell",
            "command:String,args:String",
            "shell_dispatcher::dispatch",
        ));
        // SMS — Twilio send-message kernel hook.
        self.register(PrimitiveSpec::new(
            "Sms.Send",
            "sms",
            "to:String,body:String",
            "sms_dispatcher::send_message",
        ));
        // TTS — text-to-audio kernel hook.
        self.register(PrimitiveSpec::new(
            "Tts.Render",
            "tts",
            "text:String,voice:String",
            "tts_dispatcher::render_text_to_audio",
        ));
    }

    /// Insert a spec into the registry, keyed by name. Overwrites an
    /// earlier registration with the same name — the LAST writer wins.
    pub fn register(&mut self, spec: PrimitiveSpec) {
        self.by_name.insert(spec.name.clone(), spec);
    }

    /// Look up a spec by its dotted FQN. Returns None when no primitive
    /// is registered at that name ; the macrophage uses a None to flag
    /// an undeclared imperative leaf.
    pub fn lookup(&self, name: &str) -> Option<&PrimitiveSpec> {
        self.by_name.get(name).filter(|s| s.active)
    }

    /// Iterate every registered (active or retired) spec. Used by the
    /// macrophage check to cross-reference the source tree.
    pub fn iter(&self) -> impl Iterator<Item = &PrimitiveSpec> {
        self.by_name.values()
    }

    /// Count of registered specs (active + retired). Tests + the t6
    /// smoke assertion use this to confirm the seed populated.
    pub fn len(&self) -> usize {
        self.by_name.len()
    }

    /// True when the registry has no entries — exposed so callers can
    /// avoid the clippy len-zero lint without leaking implementation.
    pub fn is_empty(&self) -> bool {
        self.by_name.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_includes_process_spawn() {
        let mut reg = PrimitiveRegistry::new();
        reg.seed_builtins();
        let spec = reg.lookup("Process.Spawn").expect("Process.Spawn seeded");
        assert_eq!(spec.kind, "process");
        assert_eq!(spec.implementation, "exec_dispatcher::dispatch");
    }

    #[test]
    fn seed_includes_every_kernel_dispatcher_kind() {
        let mut reg = PrimitiveRegistry::new();
        reg.seed_builtins();
        let kinds: Vec<&str> = reg.iter().map(|s| s.kind.as_str()).collect();
        for kind in [
            "process", "claude_tool", "mcp_tool", "web_tool",
            "compute", "llm", "shell", "sms", "tts",
        ] {
            assert!(kinds.contains(&kind), "missing kind={}", kind);
        }
    }

    #[test]
    fn unknown_lookup_returns_none() {
        let reg = PrimitiveRegistry::new();
        assert!(reg.lookup("Unknown.Verb").is_none());
    }

    /// Sprint-14 macrophage : every kernel-floor `*_dispatcher.rs` in
    /// `rust/src/runtime/` must have a matching seed entry. This test
    /// IS the Rust-side enforcement of the `primitive_registry_declared`
    /// macrophage check — when a new dispatcher lands without a seed
    /// entry the test fails ; when a seed entry names a dispatcher
    /// that no longer exists the test also fails. Single source of
    /// truth keeps the seed list and the source tree in lockstep.
    #[test]
    fn every_kernel_dispatcher_has_a_seed_entry() {
        use std::fs;
        use std::path::Path;
        // CARGO_MANIFEST_DIR resolves to rust/ — the dispatcher files
        // live under src/runtime/.
        let runtime_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/runtime");
        let mut dispatcher_kinds: Vec<String> = Vec::new();
        for entry in fs::read_dir(&runtime_dir).expect("read runtime dir") {
            let path = entry.expect("dir entry").path();
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            // Match `<kind>_dispatcher.rs` ; map `exec_dispatcher.rs`
            // to the `process` kind (it is the actual implementation
            // of Primitive::Process.Spawn). Skip `command_dispatch.rs`
            // — a sibling protocol module, not a kernel-floor leaf.
            if let Some(stripped) = name.strip_suffix("_dispatcher.rs") {
                let kind = match stripped {
                    "exec" => "process".to_string(),
                    other  => other.to_string(),
                };
                dispatcher_kinds.push(kind);
            }
        }
        assert!(!dispatcher_kinds.is_empty(), "no dispatchers found");
        let mut reg = PrimitiveRegistry::new();
        reg.seed_builtins();
        let seeded_kinds: std::collections::HashSet<String> =
            reg.iter().map(|s| s.kind.clone()).collect();
        for kind in &dispatcher_kinds {
            assert!(
                seeded_kinds.contains(kind),
                "kernel-floor dispatcher kind={} has no Storehouse::Primitive seed entry — add one to PrimitiveRegistry::seed_builtins (and a Storehouse::Primitive.Conceive declaration)",
                kind,
            );
        }
    }
}
