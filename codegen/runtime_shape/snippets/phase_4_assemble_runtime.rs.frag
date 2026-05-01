        Runtime {
            domain,
            repositories,
            event_bus: EventBus::new(),
            policy_engine,
            projections,
            middleware: MiddlewareStack::new(),
            data_dir,
        }
