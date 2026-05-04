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
        }
