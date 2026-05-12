//! FrameworkRegistry — typed runtime registry for Phase-2 framework
//!
//! i557 names the Phase-2 framework runtime: at boot, walk
//! `framework/adapter_families/` + `framework/behavior_kinds/`, build
//! typed registries from the bluebook definitions, and route dispatch
//! through them. Today the parser already stamps `framework_kind` on
//! Hecksagon IR but the runtime ignores it — this module is the home
//! for the lookup + invocation surface that will close that gap.
//!
//! Contract:
//!   - `AdapterFamily` describes a category of adapter declared under
//!     `framework/adapter_families/<name>.bluebook`. Fields, trigger
//!     attribute, response attribute, and the behavior it implements
//!     come from the bluebook ; `providers` lists concrete impls.
//!   - `BehaviorKind` describes a verb the kernel can run on behalf of
//!     a family (`framework/behavior_kinds/<name>.bluebook`). It names
//!     the fields the behavior requires and which command attribute
//!     triggers it.
//!   - `KernelHook` is the native function the runtime calls when a
//!     family's behavior fires. The registry stores hooks by behavior
//!     name so a dispatch knows which closure to run.
//!   - `FrameworkRegistry` is the lookup table: family + behavior maps
//!     keyed by name plus the hook map. `discover` walks a root and
//!     populates the maps ; `lookup_for_kind` resolves a
//!     `framework_kind` on an IR adapter to the family that owns it.
//!
//! Usage (shape, not yet wired into mod.rs):
//!   let mut reg = FrameworkRegistry::discover(&root);
//!   reg.register_hook("respond", llm_respond_hook);
//!   if let Some(family) = reg.lookup_for_kind("llm") { ... }
//!
//! This file is intentionally orphan: not declared as `mod
//! framework_registry;` in `runtime/mod.rs` yet. The dispatcher
//! integration that wires it in is the next step of i557 and is being
//! done concurrently in another worktree — keeping this file dead
//! avoids a merge race while still landing the design surface.
//!
//! [antibody-exempt: rust/src/runtime/framework_registry.rs —
//!  kernel-floor module. The framework registry is what *enables*
//!  bluebook-driven dispatch ; it cannot itself be bluebook-described
//!  until the very mechanism it provides is live. Retire this marker
//!  when `framework/adapter_families/` + `framework/behavior_kinds/`
//!  generate this module via the meta-shape compiler (i557 follow-up).]

use std::collections::HashMap;
use std::path::Path;

/// A category of adapter declared under
/// `framework/adapter_families/<name>.bluebook`.
///
/// Example: an `llm` family has fields like `provider`, `model`,
/// `prompt`, with `prompt` as the trigger attribute, `response` as the
/// response attribute, and `respond` as the behavior. Providers list
/// the concrete adapter names that implement the family.
#[derive(Debug, Clone, Default)]
pub struct AdapterFamily {
    pub name: String,
    pub fields: Vec<String>,
    pub trigger_field: Option<String>,
    pub response_field: Option<String>,
    pub behavior: Option<String>,
    pub providers: Vec<String>,
}

/// A verb the kernel can run on behalf of a family.
///
/// Declared under `framework/behavior_kinds/<name>.bluebook`. Names the
/// fields required to invoke the behavior and which command attribute
/// triggers it at dispatch time.
#[derive(Debug, Clone, Default)]
pub struct BehaviorKind {
    pub name: String,
    pub requires_fields: Vec<String>,
    pub trigger_attribute: Option<String>,
}

/// Native handler bound to a behavior name.
///
/// The runtime calls this when a family's behavior fires. v1 shape:
/// receives the resolved family + the command attribute map, returns
/// the response string that the dispatcher will fold back into the
/// command result. Future iterations may widen the return type to a
/// structured value once we know what behaviors need beyond a single
/// scalar response.
pub type KernelHook = Box<dyn Fn(&AdapterFamily, &HashMap<String, String>) -> String + Send + Sync>;

/// Typed registry of framework families, behaviors, and their hooks.
///
/// One instance per running domain ; populated at boot by
/// `discover(root)` then enriched with native hooks via
/// `register_hook`. The dispatcher consults `lookup_for_kind` when an
/// IR adapter carries a `framework_kind` to find the family that owns
/// it.
#[derive(Default)]
pub struct FrameworkRegistry {
    pub adapter_families: HashMap<String, AdapterFamily>,
    pub behavior_kinds: HashMap<String, BehaviorKind>,
    pub kernel_hooks: HashMap<String, KernelHook>,
}

impl FrameworkRegistry {
    /// Empty registry — no families, no behaviors, no hooks.
    ///
    /// Useful for tests and for the boot path before discovery has run.
    pub fn new() -> Self {
        FrameworkRegistry {
            adapter_families: HashMap::new(),
            behavior_kinds: HashMap::new(),
            kernel_hooks: HashMap::new(),
        }
    }

    /// Walk `<root>/framework/adapter_families/` and
    /// `<root>/framework/behavior_kinds/` and populate the registry.
    ///
    /// Stub today — the parser surface that reads these bluebooks lives
    /// elsewhere and the discovery wiring is i557's next slice. For now
    /// this returns an empty registry so callers can compose with the
    /// real shape without depending on the not-yet-built reader.
    pub fn discover(_root: &Path) -> Self {
        // TODO(i557): walk <root>/framework/adapter_families/*.bluebook
        // + <root>/framework/behavior_kinds/*.bluebook, parse each
        // file, populate `adapter_families` + `behavior_kinds`. The
        // bluebook reader for these directories is the next slice.
        Self::new()
    }

    /// Insert a native handler bound to a behavior name.
    ///
    /// Behaviors are bluebook-declared but their implementations are
    /// native code that the kernel ships ; this is the seam between
    /// the two. The dispatcher will look up the hook by behavior name
    /// when a family fires.
    pub fn register_hook(&mut self, name: &str, hook: KernelHook) {
        self.kernel_hooks.insert(name.to_string(), hook);
    }

    /// Resolve an IR `framework_kind` to the family that owns it.
    ///
    /// Called at dispatch time: when a Hecksagon adapter carries
    /// `framework_kind: "llm"`, the dispatcher asks the registry for
    /// the `AdapterFamily` named `"llm"` and uses its trigger /
    /// response fields + behavior to drive the call.
    pub fn lookup_for_kind(&self, kind: &str) -> Option<&AdapterFamily> {
        self.adapter_families.get(kind)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_registry_lookups_return_none() {
        let reg = FrameworkRegistry::new();
        assert!(reg.lookup_for_kind("llm").is_none());
        assert!(reg.adapter_families.is_empty());
        assert!(reg.behavior_kinds.is_empty());
        assert!(reg.kernel_hooks.is_empty());
    }
}
