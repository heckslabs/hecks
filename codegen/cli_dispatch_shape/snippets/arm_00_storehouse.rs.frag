
    // StoreHouse generic dispatcher (i484 surface). Three verbs that
    // honour the contract declared in hecks_conception/storehouse/
    // {lexicon,dispatch,query}.bluebook + companion .hecksagons :
    //
    //   storehouse storehouse route <phrase> [k=v ...]
    //     — Dispatch.Route. Walks the conception, locates the bluebook
    //       declaring the phrase's Aggregate.Command, invokes it via
    //       run::run_script with `entrypoint=<phrase>`. The chain
    //       (Lookup → bind → Invoke) lives here imperatively today ;
    //       i493 grows the runtime so the storehouse bluebooks become
    //       self-evidencing (bind directive, dotted templates, cross-
    //       aggregate auto-dispatch). When that lands, this shim
    //       retires through the same path.
    //
    //   storehouse storehouse compile [conception_root]
    //     — Lexicon.Compile. Walks bluebooks, writes lexicon.heki rows
    //       (one per phrase + a singleton row carrying CompiledAt +
    //       PhraseCount). Idempotent.
    //
    //   storehouse storehouse read <Aggregate.attribute>
    //     — Query.Read. Resolves heki path via heki::path_for_lookup,
    //       projects the named attribute from the latest record,
    //       prints the flattened value.
    //
    //   storehouse storehouse list [filter]
    //     — Lexicon.List. Recompiles if stale (mtime check), prints
    //       the matching phrases.
    //
    //   storehouse storehouse lookup <phrase>
    //     — Lexicon.Lookup. Recompiles if stale, prints the resolved
    //       target as JSON ({phrase, bluebook_path, aggregate, command}).
    if command == "storehouse" {
        std::process::exit(run_storehouse(&args));
    }
