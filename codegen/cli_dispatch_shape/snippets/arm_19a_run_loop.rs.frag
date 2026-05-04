
    // `hecks-life run-loop <bluebook-tree> [--every <dur>] [--emit <Event:Type:Id>]
    //   [--dispatch <Aggregate.Command> [--with k=v ...]]`
    //
    // PM loop driver — long-running runtime daemon. Boots once, ticks
    // at the configured cadence, fires registered events / commands
    // into the runtime so PMs (sleep_cycle, dream, mind, ...) advance
    // their state continuously instead of one-shot per shell invocation.
    //
    // Substrate for retiring `mindstream.sh` : that shell exists because
    // no Rust scheduler does. With run-loop the cadence becomes Rust
    // and the bluebook-declared PMs react to each tick's events through
    // the same pm_engine + drain_policies machinery the one-shot
    // dispatch path already uses.
    //
    // Today the cadence + actions are passed via CLI flags ; once
    // block_grammar (i218) lifts the `cadence ... every Xs` keyword
    // into Rust IR, run-loop reads them from the parsed Domain and
    // mindstream.sh retires entirely. This subcommand IS the
    // long-running substrate that lift requires.
    if command == "run-loop" {
        run_pm_loop(&args);
        return;
    }
