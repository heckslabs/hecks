//! boot_persistent — the runtime constructors, persistent half.
//! `boot_with_data_dir` (the store-backed boot every deployment uses —
//! hecksagon persistence resolution, world dirs, seed loading, event-log
//! read-side hydration) and `boot_with_framework_dir`. The ephemeral half
//! lives in boot.rs — one concern, two <=200 casks.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 2).
//!
//! [antibody-exempt: rust/src/runtime/boot_persistent.rs — kernel-floor
//!  construction, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    pub fn boot_with_data_dir(domain: Domain, data_dir: Option<String>) -> Self {
        // TRANSITIONAL — first-class factories phase 1 (phase 2 DELETES
        // this). Factories become dispatchable by materializing a Command
        // view into the RUNTIME's in-memory command table only ; the
        // parsed IR (dumps, parity, validators) keeps factories separate.
        // The two-path dispatch split (Factory → mint / Command → load)
        // replaces this seam wholesale.
        let domain = Self::materialize_factory_commands(domain);
        let mut repositories = HashMap::new();
        for agg in &domain.aggregates {
            // i142 Tier 2 — key repositories by (context, name) so
            // same-name aggregates in different contexts get distinct
            // Repository instances (and distinct heki paths).
            let key = repo_key(agg.context.as_deref(), &agg.name);
            repositories.insert(
                key,
                // i-lazy — construct lazily : no disk read here. The
                // repo hydrates (via Repository::new_with_context) on
                // first find/all/save/etc. Single-shot dispatches touch
                // one repo ; daemons warm each on first touch.
                LazyRepository::new(
                    &agg.name,
                    crate::heki::realm_store_dir(
                        agg.realm_path.as_deref(),
                        data_dir.as_deref(),
                    ),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                ),
            );
        }

        let mut policy_engine = PolicyEngine::new();
        for policy in &domain.policies {
            policy_engine.register(policy);
        }

        let mut pm_engine = PMEngine::new();
        for pm in &domain.process_managers {
            pm_engine.register(pm);
        }
        // Phase D — load persisted PM instances from heki so transitions
        // resume across storehouse subprocess forks (production daemons
        // fork per dispatch ; without this, in-memory state evaporates
        // and PMs effectively don't accumulate).
        pm_engine.load_persisted(data_dir.as_deref());

        let projections = domain
            .aggregates
            .iter()
            .map(|agg| projection::auto_projection(&agg.name))
            .collect();

        let mut rt = Runtime {
            domain,
            repositories,
            refused_persistence: HashMap::new(),
            event_bus: EventBus::new(),
            outbox: std::collections::VecDeque::new(),
            policy_engine,
            pm_engine,
            projections,
            middleware: MiddlewareStack::new(),
            data_dir,
            hecksagons: Vec::new(),
            llm_providers: HashMap::new(),
            // Booted on demand by `framework_mut()`, never eagerly.
            framework: None,
            // i557 part 1 — boot without a framework dir leaves the
            // family + behavior maps empty but still seeds the native
            // kernel hooks. Discovery-aware callers use
            // `boot_with_framework_dir` (or set the field directly).
            framework_registry: framework_registry::FrameworkRegistry::build_from_dir(
                std::path::Path::new("/nonexistent")
            ),
            primitive_registry: {
                // sprint-14 — seed every runtime with the current
                // kernel-floor primitives. Boot-without-framework still
                // gets the imperative-leaf index because the seed list
                // is structural to the runtime (the dispatchers ship in
                // the binary), not contingent on a framework conception
                // path. Future overlay from the Storehouse::Primitive
                // .heki store can layer on top here.
                let mut reg = primitive_registry::PrimitiveRegistry::new();
                reg.seed_builtins();
                reg
            },
            world_servers: Vec::new(),
            world_servers_path: None,
            world_adapter_bindings: Vec::new(),
            world_configs: Vec::new(),
            #[cfg(not(target_arch = "wasm32"))]
            mailbox_drained: 0,
            #[cfg(not(target_arch = "wasm32"))]
            mailbox_registry: actor::Mailboxes::new(),
            aggregates_root: None,
            last_event_id_by_agg: HashMap::new(),
            current_auth: None,
            current_correlation: None,
            chain_head: None,
            event_rows_owed: 0,
            event_rows_written: 0,
            acl_read_model: acl_readmodel::AclReadModel::empty(),
        };
        // Hydrate the RBAC read-model from Agent state (covers the bare
        // boot path). boot_with_hecksagons re-hydrates after persistence
        // overrides so it reads the final repositories.
        let m = acl_readmodel::AclReadModel::hydrate(&rt);
        rt.acl_read_model = m;
        // Hydrate the middleware stack (runtime projection of the Gate registry).
        rt.hydrate_middleware();
        rt
    }

    /// i557 part 1 — boot with hecksagons AND a framework directory so
    /// the registry can discover adapter families + behavior kinds at
    /// boot. The framework dir is typically
    /// `<aggregates_dir>/framework` (e.g.
    /// `hecks_conception/aggregates/framework`). Falls back to the
    /// kernel-hook-only registry if the dir doesn't exist — safe for
    /// callers that don't ship a framework conception.
    ///
    /// `Runtime::dispatch` itself doesn't consult the registry yet
    /// (part 2 retires the hardcoded `:claude_tool` path) ; this
    /// constructor just lands the substrate.
    pub fn boot_with_framework_dir(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
        framework_dir: &std::path::Path,
    ) -> Self {
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        rt.framework_registry =
            framework_registry::FrameworkRegistry::build_from_dir(framework_dir);
        // THE READ SIDE (Stage 4) : state for an event_sourced aggregate is DERIVED
        // from the Log rather than merely mirrored beside it. Runs here, not in
        // boot_with_data_dir, because `event_sourced` is a HECKSAGON binding — the
        // directive is unknowable until the line above. Overlays the Log's opinion
        // onto what the store loaded, so a store that is stale, truncated or gone
        // no longer decides what a reader sees.
        rt.hydrate_event_sourced_from_log();
        rt
    }
}
