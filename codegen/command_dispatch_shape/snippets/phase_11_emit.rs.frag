    let event = build_event_res(rt, res, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        // Sprint 14 (retire-sync-cascade-pipeline) — the legacy Sync vs.
        // Actor fork retired. Every aggregate publishes inline through the
        // event bus ; the `delivery :actor` mailbox-stub path is gone. The
        // actor-per-aggregate-instance + async-event-delivery-bus stories
        // will rewire publishing into per-mailbox enqueueing later without
        // a bluebook-visible fork — the runtime is the swappable substrate.
        rt.event_bus.publish(evt.clone());
    }
