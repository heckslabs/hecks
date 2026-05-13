        Runtime {
            domain,
            repositories,
            event_bus: EventBus::new(),
            policy_engine,
            pm_engine,
            projections,
            middleware: MiddlewareStack::new(),
            data_dir,
            hecksagons: Vec::new(),
            llm_providers: HashMap::new(),
            // i557 part 1 — boot without a framework dir leaves the
            // family + behavior maps empty but still seeds the native
            // kernel hooks. Discovery-aware callers use
            // `boot_with_framework_dir` (or set the field directly).
            framework_registry: framework_registry::FrameworkRegistry::build_from_dir(
                std::path::Path::new("/nonexistent")
            ),
        }
