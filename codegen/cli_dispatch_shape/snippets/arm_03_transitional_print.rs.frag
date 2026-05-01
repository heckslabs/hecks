
    // These commands now dispatch through the hecksagon:
    //   speak → Speech.Speak, status → Heartbeat.ReadVitals,
    //   boot → Identity.Identify
    // (`daemon` was on this list when it meant "start mindstream.sh" ;
    // it now names the process-lifecycle primitive and dispatches via
    // run_daemon below.)
    if command == "speak" || command == "status" || command == "musings"
        || command == "boot" {
        eprintln!("'{}' now dispatches through the hecksagon:", command);
        eprintln!("  hecks-life aggregates/ Aggregate.Command");
        return;
    }
