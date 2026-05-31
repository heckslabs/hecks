    let event = build_event_res(rt, res, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        // Sprint 14 (migration-coexistence) — fork on the aggregate's
        // declared `delivery` mode. `Sync` (default for every aggregate
        // without `delivery :actor`) publishes inline as today. `Actor`
        // routes through `enqueue_and_drain`, the per-aggregate mailbox
        // stub. The stub publishes synchronously too (see the helper's
        // doc comment) so behavior is byte-equivalent ; the difference
        // is observable on `Runtime::mailbox_drained` which behaviors
        // tests assert on to prove the fork fired.
        match rt.delivery_for(&evt.aggregate_type) {
            crate::ir::DeliveryMode::Sync => rt.event_bus.publish(evt.clone()),
            crate::ir::DeliveryMode::Actor => rt.enqueue_and_drain(evt.clone()),
        }
    }
