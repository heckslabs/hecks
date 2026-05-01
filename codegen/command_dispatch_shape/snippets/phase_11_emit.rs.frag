    let event = build_event_res(rt, res, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        rt.event_bus.publish(evt.clone());
    }
