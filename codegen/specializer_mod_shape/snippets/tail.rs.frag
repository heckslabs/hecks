        other => Err(format!(
            "unknown specializer target: {}. Known: adapter_llm, aggregate_state, assemble, behaviors_fixtures, behaviors_parser, behaviors_runner, command_dispatch, conceiver_generator, conception_kernel_sample, discover, dispatch_query, dump, fixtures_parser, hecksagon_ir, hecksagon_parser, heki_query, html_domain, interpreter, ir, lifecycle_validator, parse_blocks, parser, parser_helpers, repository, specializer_mod, system_prompt, validator, validator_corpus, validator_warnings",
                other
            )
            .into()),
        }
    }

    /// Emit a single named section of a multi-section specializer target.
    /// No target supports sections today — the `runtime` section sub-target
    /// was retired with codegen/runtime_shape. Kept as an honest error surface
    /// so the `--section` CLI flag fails loudly rather than silently doing
    /// nothing.
    pub fn emit_section(
        target: &str,
        repo_root: &Path,
        section: &str,
    ) -> Result<String, Box<dyn Error>> {
        let _ = (repo_root, section);
        Err(format!(
            "specializer target '{}' does not support --section (no target supports sections)",
            target
        )
        .into())
    }
