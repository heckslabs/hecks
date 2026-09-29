require "spec_helper"

# ADR 0080, section 7: every Codebase row of the command table, by script, and the launcher verbs
# that answer it. A row with no answer fails here. spec/hecks_codebase_table_spec.rb checks each
# verb in depth (it refuses outside a checkout); this spec is the ledger: it lists the rows as the
# ADR states them, names each deliberate difference, and checks the domain holds nothing the
# ledger does not account for.
RSpec.describe "the Codebase rows of the ADR table" do
  # One row of the table: the script, the verbs that answer it, and any deliberate difference.
  AdrRow = Struct.new(:script, :verbs, :note, keyword_init: true)

  # Every Codebase row of section 7, as the ADR lists it. `note` says how the domain differs.
  ADR_CODEBASE_ROWS = [
    AdrRow.new(script: "project_model", verbs: %w[project_model]),
    AdrRow.new(script: "project_vocabulary", verbs: %w[project_vocabulary]),
    AdrRow.new(script: "project_rust_vocabulary", verbs: %w[project_rust_vocabulary]),
    AdrRow.new(script: "project_refusal_wording", verbs: %w[project_refusal_wording],
               note: "a second command that carries out the same operation, since a verb has one name"),
    AdrRow.new(script: "project_reserved_names", verbs: %w[project_reserved_names]),
    AdrRow.new(script: "project_parser_table", verbs: %w[project_parser_table]),
    AdrRow.new(script: "project_bootstrap_table", verbs: %w[project_bootstrap_table]),
    AdrRow.new(script: "project_field_hints", verbs: %w[project_field_hints]),
    AdrRow.new(script: "expression_projection", verbs: %w[project_expression_tables]),
    AdrRow.new(script: "reference", verbs: %w[project_reference]),
    AdrRow.new(script: "evolve",
               verbs:  %w[word_status propose admit deprecate retire rename propose_argument admit_argument
                          deprecate_argument retire_argument],
               note:   "rename takes new_name=, since `to` is the launcher's receiver key"),
    AdrRow.new(script: "project_kernel_capabilities", verbs: %w[project_kernel_capabilities],
               note: "the command is ProjectKernelCapabilities; the launcher verb is its snake name"),
    AdrRow.new(script: "rust_kernel_coverage", verbs: %w[measure_kernel_coverage],
               note: "the command is MeasureKernelCoverage; the launcher verb is its snake name"),
    AdrRow.new(script: "check_engine_agreement", verbs: %w[check_engine_agreement]),
    AdrRow.new(script: "doc_coverage", verbs: %w[measure_doc_coverage]),
    AdrRow.new(script: "argument_gate_matrix", verbs: %w[argument_gate_matrix]),
    AdrRow.new(script: "regen_codegen_domains", verbs: %w[regenerate_corpus]),
    AdrRow.new(script: "standardize_comments",
               verbs:  %w[report_comments check_comments fix_comments write_comment_baseline check_comments_unchanged]),
    AdrRow.new(script: "standardize_comments_rust",
               verbs:  %w[report_rust_comments check_rust_comments fix_rust_comments]),
    AdrRow.new(script: "canonicalise", verbs: %w[canonicalise]),
    AdrRow.new(script: "codemod_hoist_local_givens", verbs: %w[hoist_local_givens]),
    AdrRow.new(script: "codemod_implicit_append_fields", verbs: %w[drop_implicit_append_fields]),
    AdrRow.new(script: "rspec_shard_files", verbs: %w[shard_specs]),
    AdrRow.new(script: "rspec_io_parallel_files", verbs: %w[list_io_parallel_specs write_io_parallel_spec_list],
               note: "the table's write= is its own confirmed command, since a query never writes"),
    AdrRow.new(script: "refresh_rspec_runtime_baseline", verbs: %w[refresh_runtime_baseline]),
    AdrRow.new(script: "spec_example", verbs: %w[run_spec_example]),
    AdrRow.new(script: "stress_concurrency_specs", verbs: %w[stress_concurrency]),
    AdrRow.new(script: "regenerate_persistence_legacy_fixtures", verbs: %w[regenerate_legacy_fixtures]),
    AdrRow.new(script: "seed_semantics_corpus", verbs: %w[seed_semantics_corpus]),
    AdrRow.new(script: "pattern-cases", verbs: %w[record_pattern_cases],
               note: "a query: it prints JSON and writes nothing"),
    AdrRow.new(script: "corpus", verbs: %w[rust_domains regen_order corpus_rust_coverage]),
    AdrRow.new(script: "query_ir", verbs: %w[ir_constructs ir_duplicates ir_impact]),
    AdrRow.new(script: "hecks_query_ir_mcp", verbs: %w[serve_query_ir_mcp]),
    AdrRow.new(script: "present", verbs: %w[present]),
    AdrRow.new(script: "release", verbs: %w[publish],
               note: "without --confirm it is the old --dry-run; --gem-only, --npm-only, --npm-local and " \
                     "--no-wait are booleans (--yes is --confirm)"),
    AdrRow.new(script: "release_gem", verbs: %w[publish_gem])
  ].freeze

  # The aggregates of codebase.bluebook: each holds commands a maintainer runs in a checkout.
  CODEBASE_RECORDS = %w[LanguageRun KernelRun ConformanceRun RegenerationRun StyleRun CodemodRun TestSuiteRun
                        CorpusRun PublishingRun].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
    @bluebook = @hecks.registry.bluebook("Hecks")
  end

  def launch(argv)
    Hecks::Facade::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  # Every verb a maintainer may run: a command a Maintainer role holds, or a query.
  def domain_verbs
    CODEBASE_RECORDS.flat_map do |name|
      aggregate = @bluebook.aggregate(name)
      commands = aggregate.commands.reject { |command| command.role.to_s == "System" }.map(&:hecks_name)
      (commands + aggregate.queries.map(&:hecks_name)).map { |verb| verb.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase }
    end
  end

  ADR_CODEBASE_ROWS.each do |row|
    row.verbs.each do |verb|
      it "answers #{row.script} with `hecks #{verb}`" do
        out, status = launch([verb, "--help"])

        expect(status).to eq(0), "no launcher verb #{verb} for the row #{row.script}: #{out.lines.first}"
        expect(out).to start_with(verb)
      end
    end
  end

  it "lists each script once, and every deliberate difference in words" do
    expect(ADR_CODEBASE_ROWS.map(&:script).uniq.size).to eq(ADR_CODEBASE_ROWS.size)
    expect(ADR_CODEBASE_ROWS.flat_map(&:verbs).uniq.size).to eq(ADR_CODEBASE_ROWS.sum { |row| row.verbs.size })
    expect(ADR_CODEBASE_ROWS.filter_map(&:note)).to all(be_a(String))
  end

  it "leaves no Codebase command or query that no row accounts for" do
    listed = ADR_CODEBASE_ROWS.flat_map(&:verbs)
    outcomes = %w[language_outcome kernel_outcome conformance_outcome regeneration_outcome style_outcome
                  codemod_outcome test_suite_outcome corpus_outcome publishing_outcome]
    faults = %w[language_faulted kernel_faulted conformance_faulted regeneration_faulted style_faulted
                codemod_faulted test_suite_faulted corpus_faulted publishing_faulted]

    unaccounted = domain_verbs - listed - outcomes - faults

    expect(unaccounted).to eq([]), "verbs with no row of the ADR table: #{unaccounted.join(', ')}"
  end

  it "leaves no row of the table without a verb the domain declares" do
    missing = ADR_CODEBASE_ROWS.flat_map(&:verbs) - domain_verbs

    expect(missing).to eq([]), "rows with no command or query in the domain: #{missing.join(', ')}"
  end
end
