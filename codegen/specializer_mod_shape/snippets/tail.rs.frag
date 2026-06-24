        other => Err(format!(
            "unknown specializer target: {}. Known: adapter_llm, aggregate_state, assemble, behaviors_fixtures, behaviors_parser, behaviors_runner, cli_dispatch, command_dispatch, conceiver_generator, conception_kernel_sample, discover, dispatch_query, dump, fixtures_parser, hecksagon_ir, hecksagon_parser, heki_query, html_domain, interpreter, ir, lifecycle_validator, parse_blocks, parser, parser_helpers, repository, runtime, run_statusline, specializer_mod, system_prompt, validator, validator_corpus, validator_warnings",
                other
            )
            .into()),
        }
    }

    /// Emit a single named section of a multi-section specializer target — the
    /// scoped sub-target behind `storehouse specialize <target> --section
    /// <name>`. Powers the per-concern byte-identity goldens the
    /// runtime-as-bluebook strangler relies on (see
    /// inbox/runtime-as-bluebook.md). Only `runtime` supports sections today ;
    /// other targets return an error naming the limitation.
    pub fn emit_section(
        target: &str,
        repo_root: &Path,
        section: &str,
    ) -> Result<String, Box<dyn Error>> {
        match target {
            "runtime" => runtime::root::emit_section(repo_root, section),
            other => Err(format!(
                "specializer target '{}' does not support --section (only 'runtime' does)",
            other
        )
        .into()),
    }
}
