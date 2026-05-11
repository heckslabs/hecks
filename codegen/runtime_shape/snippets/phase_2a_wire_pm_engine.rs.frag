        let mut pm_engine = PMEngine::new();
        for pm in &domain.process_managers {
            pm_engine.register(pm);
        }
        // Phase D — load persisted PM instances from heki so transitions
        // resume across storehouse subprocess forks (production daemons
        // fork per dispatch ; without this, in-memory state evaporates
        // and PMs effectively don't accumulate).
        pm_engine.load_persisted(data_dir.as_deref());

