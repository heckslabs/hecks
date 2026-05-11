
    if command == "test" {
        // i500 — universal `.behaviors` runner. CLI glue around the
        // existing run_suite_with_domain / run_suite_with_fixtures
        // engine. File OR directory, filter/aggregate/format flags,
        // structured exit codes (0/1/2/3).
        std::process::exit(run_test(&args));
    }
