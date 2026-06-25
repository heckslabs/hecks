        let mut policy_engine = PolicyEngine::new();
        for policy in &domain.policies {
            policy_engine.register(&policy.name, &policy.on_event, &policy.trigger_command);
        }

