//! boot — the runtime constructors, ephemeral half. `boot` (heki-backed
//! default), `boot_with_hecksagons`, and the two `boot_in_memory*` forms
//! every test reaches for. The persistent half (data-dir / framework-dir
//! boots) lives in boot_persistent.rs — one concern, two <=200 casks.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 2).
//!
//! [antibody-exempt: rust/src/runtime/boot.rs — kernel-floor construction
//!  (the runtime cannot bluebook its own constructor), relocated verbatim
//!  from mod.rs blanket.]

use super::*;

impl Runtime {
    pub fn boot(domain: Domain) -> Self {
        Self::boot_with_data_dir(domain, None)
    }

    /// i221 — boot with hecksagons attached so the LLM dispatcher's
    /// `drain_policies` hook can resolve `:llm` adapters whose
    /// `response_into_target` references a freshly-dispatched command.
    pub fn boot_with_hecksagons(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
    ) -> Self {
        // No substrate graft. The outbox lives in the framework collaborator,
        // so a domain with an effect port reaches it by CALLING rather than by
        // having it merged in. `ensure_outbox_substrate` used to splice the
        // OutboundEvent aggregate into any domain with an effect binding —
        // which is how ToolShed came to render the framework outbox as one of
        // its own modules.
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        // Persistence override (i642) — when a hecksagon declares
        // `adapter :sqlite, db: "..."`, rebuild every repository on the
        // SQL backend pointed at that db. Default (memory/heki) leaves
        // the heki-backed repos built by boot_with_data_dir untouched.
        // Runs AFTER hecksagons attach because boot_with_data_dir has no
        // hecksagon in scope to read the override from.
        // sqlite override is host-only ; on wasm32 the Worker always
        // runs the in-memory repository (the rusqlite dep is gated out).
        // Resolve every wired persistence binding against the adapter
        // registry. The composition root (storehouse-cli) registers concrete
        // adapters (sqlite, ...) BEFORE boot ; the lib names no engine.
        #[cfg(not(target_arch = "wasm32"))]
        rt.apply_wired_adapters();
        // i728 keystone — make `adapter :memory` actually select Backend::Memory.
        // Until this ran, :memory was inert : a declared-:memory aggregate fell
        // through to the implicit heki default, indistinguishable from unwired.
        // Ungated — memory is host- AND wasm-valid, so it runs on every target.
        rt.apply_memory_persistence();
        // bucket-3 step 4 — the hexagon-binding CONSULT. Reads the NEW
        // port-verb binding surface (`Pizzas::Order.persisted_by("Heki")`)
        // that steps 1-3 parse + resolve, and rebuilds each
        // persistence-family-bound aggregate on the backend its adapter
        // names. Runs LAST so a binding (the new surface) wins over a legacy
        // persistence block ; additive for every aggregate with no binding.
        rt.apply_hexagon_persistence();
        // Re-hydrate the RBAC read-model AFTER persistence overrides, so it
        // reads Role/Agent from the final (possibly sqlite) repositories.
        let m = acl_readmodel::AclReadModel::hydrate(&rt);
        rt.acl_read_model = m;
        // Hydrate the middleware stack (runtime projection of the Gate
        // grammar) after the RBAC read-model the authorize gate reads.
        rt.hydrate_middleware();
        // THE READ SIDE (Stage 4) : derive event_sourced state FROM the Log.
        // LAST, after every persistence override above — the overrides REBUILD
        // repositories, so hydrating earlier would seed records into a repo that
        // is then replaced. This is the door the cold CLI boots through ; a
        // cold-CLI smoke is what caught that wiring only boot_with_framework_dir
        // left every one-shot `storehouse` invocation reading the store alone.
        rt.hydrate_event_sourced_from_log();
        rt
    }

    /// Test-harness boot (i735 plan step 4) : every aggregate gets the
    /// EXPLICIT in-process `Backend::Memory` repository, not the implicit
    /// `Backend::Heki { data_dir: None }` default. "The harness chooses its
    /// storage" — in-process, no disk, alive for the process and gone on
    /// restart. The behaviors runner boots through this so the corpus stays
    /// explicitly wired once the unwired-=-error enforcement flip lands.
    pub fn boot_in_memory(domain: Domain) -> Self {
        let mut rt = Self::boot(domain);
        rt.force_memory_repositories();
        rt
    }

    /// `boot_in_memory` + attached hecksagons, so the behaviors runner's
    /// `driven on` adapter handlers still fire while every repository is
    /// memory-backed.
    pub fn boot_in_memory_with_hecksagons(domain: Domain, hecksagons: Vec<Hecksagon>) -> Self {
        let mut rt = Self::boot_with_hecksagons(domain, None, hecksagons);
        rt.force_memory_repositories();
        rt
    }

    /// TRANSITIONAL — first-class factories phase 1 ; phase 2 deletes
    /// this with the two-path dispatch split. Each Factory gains a
    /// Command VIEW in the runtime's command table so the existing
    /// index-based Resolution / cmd_for machinery dispatches factory
    /// verbs unchanged. is_create truth comes from the factories vec
    /// (see command_dispatch phase_03_prepare), never from the view.
    pub(super) fn materialize_factory_commands(mut domain: Domain) -> Domain {
        for agg in &mut domain.aggregates {
            for f in agg.factories.clone() {
                if agg.commands.iter().any(|c| c.name == f.name) { continue; }
                agg.commands.push(crate::ir::Command {
                    name: f.name,
                    description: f.description,
                    role: f.role,
                    attributes: f.attributes,
                    references: f.references,
                    emits: f.emits,
                    emits_identified_by: f.emits_identified_by,
                    givens: f.givens,
                    mutations: f.mutations,
                    // A factory is never a governed door ; it mints an
                    // aggregate, it does not replace a native tool.
                    redirects_native: vec![],
                });
            }
        }
        domain
    }

    /// i221 — register an LLM provider under a backend name. Lets the
    /// caller wire `:claude` / `:ollama` (or test doubles) without
    /// touching the dispatcher. Idempotent on the key.
    pub fn register_llm_provider(
        &mut self,
        backend: impl Into<String>,
        provider: Box<dyn llm_providers::LlmProvider>,
    ) {
        self.llm_providers.insert(backend.into(), provider);
    }

}
