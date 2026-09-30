require "spec_helper"

# ADR 0080, section 7: the whole command table in one place. Every script `bin/` holds is a row;
# each row names the chapter, the aggregate and the command (or query) that replaces it, and the
# launcher verb that answers it. A row passes when the command is declared in its chapter and
# `hecks <verb> --help` answers through the launcher. A row whose command does not exist yet is a
# `gap:` row: it is pending, so the report names it, and the moment the command lands the example
# fails until the `gap:` is removed. Nothing here replaces the per-section specs
# (hecks_custodian_table_spec.rb, hecks_codebase_adr_rows_spec.rb, hecks_deploy_table_spec.rb),
# which check their rows in more depth.
RSpec.describe "the ADR 0080 command table, every row" do
  # One command of the table. `verb` is the command's snake name; `launch` is the spelling the
  # launcher answers to when it differs; `gap` says why the command is not declared yet.
  TableRow = Struct.new(:script, :chapter, :aggregate, :verb, :launch, :gap, keyword_init: true) do
    def name = verb.split("_").map(&:capitalize).join
    def launcher_verb = launch || verb
    def argv = [*(chapter == "Hecks" ? [] : [chapter.gsub(/([a-z])([A-Z])/, '\1_\2').downcase]), *launcher_verb.split]
    def help_name = launcher_verb.split.last
  end

  def self.rows(script, chapter, aggregate, verbs, gap: nil)
    Array(verbs).map do |verb|
      launch = verb.is_a?(Hash) ? verb.values.first : nil
      verb = verb.keys.first if verb.is_a?(Hash)
      TableRow.new(script: script, chapter: chapter, aggregate: aggregate, verb: verb, launch: launch, gap: gap)
    end
  end

  # Custodian and Codebase rows live in the Hecks chapter, Deploy and QualityControl in the
  # attached chapters of the same names.
  CUSTODIAN = [
    ["ir", "Introspection", "ir"], ["shape", "Introspection", "shape"],
    ["stores", "Introspection", "stores"], ["history", "Introspection", "history"],
    ["statements", "Introspection", "statements"], ["narrate", "Introspection", "narrate"],
    ["docs", "Introspection", "docs"], ["project_diagrams", "Introspection", "project_diagrams"],
    ["project_glossary", "Introspection", "glossary"], ["model_check", "ModelCheckRun", "model_check"],
    ["run", "Operation", "run"], ["project", "Operation", "refresh_projections"],
    ["behaviors", "Operation", "run_behaviors"], ["console", "Operation", "open_console"],
    ["follow", "Operation", "follow"], ["smoke_test", "Operation", "smoke_test"],
    ["smoke_http", "Operation", "smoke_http"], ["check_era", "Host", "check_era"],
    ["merge_tail", "Era", "merge_tail"], ["reattest_era", "Era", "reattest"],
    ["backfill_era_projections", "Era", "backfill_projections"],
    ["scaffold_translation", "Era", "scaffold_translation"],
    ["translation_audit", "Era", "audit_translation"], ["translation_audit", "Era", "approve_translation"],
    ["compact", "Era", "compact"], ["heki_compact", "Era", "compact_heki"], ["(new)", "Era", "hold_first"],
    ["vendor_bluebook", "Package", "vendor"], ["project_cli", "Door", "project_cli"],
    ["hecks_mcp_door", "Door", "serve_mcp"], ["project_rust", "Build", "project_rust"],
    ["project_wasm", "Build", "build_wasm"], ["project_wasm_browser", "Build", "build_browser_wasm"],
    ["rust_coverage", "Build", "rust_coverage"], ["rust_coverage", "Build", "check_coverage_allowlist"],
    ["rust_conformance", "Build", "check_conformance"], ["rust_conformance_fuzz", "Build", "fuzz_conformance"],
    ["fuzz", "FuzzRun", "fuzz"], ["generate", "FuzzRun", "generate_sequence"], ["bench", "FuzzRun", "bench"]
  ].flat_map { |script, aggregate, verb| rows(script, "Hecks", aggregate, verb) }.freeze

  CODEBASE = [
    ["project_model", "LanguageRun", %w[project_model]],
    ["project_vocabulary", "LanguageRun", %w[project_vocabulary]],
    ["project_rust_vocabulary", "LanguageRun", %w[project_rust_vocabulary]],
    ["project_refusal_wording", "LanguageRun", %w[project_refusal_wording]],
    ["project_reserved_names", "LanguageRun", %w[project_reserved_names]],
    ["project_parser_table", "LanguageRun", %w[project_parser_table]],
    ["project_bootstrap_table", "LanguageRun", %w[project_bootstrap_table]],
    ["project_field_hints", "LanguageRun", %w[project_field_hints]],
    ["expression_projection", "LanguageRun", %w[project_expression_tables]],
    ["reference", "LanguageRun", %w[project_reference]],
    ["evolve", "LanguageRun", %w[word_status propose admit deprecate retire rename propose_argument
                                 admit_argument deprecate_argument retire_argument]],
    ["project_kernel_capabilities", "KernelRun", %w[project_kernel_capabilities]],
    ["rust_kernel_coverage", "KernelRun", %w[measure_kernel_coverage]],
    ["check_engine_agreement", "ConformanceRun", %w[check_engine_agreement]],
    ["doc_coverage", "ConformanceRun", %w[measure_doc_coverage]],
    ["argument_gate_matrix", "ConformanceRun", %w[argument_gate_matrix]],
    ["regen_codegen_domains", "RegenerationRun", %w[regenerate_corpus]],
    ["standardize_comments", "StyleRun", %w[report_comments check_comments fix_comments
                                            write_comment_baseline check_comments_unchanged]],
    ["standardize_comments_rust", "StyleRun", %w[report_rust_comments check_rust_comments fix_rust_comments]],
    ["canonicalise", "StyleRun", %w[canonicalise]],
    ["codemod_hoist_local_givens", "CodemodRun", %w[hoist_local_givens]],
    ["codemod_implicit_append_fields", "CodemodRun", %w[drop_implicit_append_fields]],
    ["rspec_shard_files", "TestSuiteRun", %w[shard_specs]],
    ["rspec_io_parallel_files", "TestSuiteRun", %w[list_io_parallel_specs write_io_parallel_spec_list]],
    ["refresh_rspec_runtime_baseline", "TestSuiteRun", %w[refresh_runtime_baseline]],
    ["spec_example", "TestSuiteRun", %w[run_spec_example]],
    ["stress_concurrency_specs", "TestSuiteRun", %w[stress_concurrency]],
    ["regenerate_persistence_legacy_fixtures", "TestSuiteRun", %w[regenerate_legacy_fixtures]],
    ["seed_semantics_corpus", "TestSuiteRun", %w[seed_semantics_corpus]],
    ["pattern-cases", "TestSuiteRun", %w[record_pattern_cases]],
    ["corpus", "CorpusRun", %w[rust_domains regen_order corpus_rust_coverage]],
    ["query_ir", "CorpusRun", %w[ir_constructs ir_duplicates ir_impact]],
    ["hecks_query_ir_mcp", "CorpusRun", %w[serve_query_ir_mcp]],
    ["present", "CorpusRun", %w[present]],
    ["release", "PublishingRun", %w[publish]],
    ["release_gem", "PublishingRun", %w[publish_gem]]
  ].flat_map { |script, aggregate, verbs| rows(script, "Hecks", aggregate, verbs) }.freeze

  DEPLOY = [
    ["project_deploy", "Recipe", "project"], ["lint_deploy_recipes", "MakefileCheck", "lint"],
    ["deploy_template_diff", "TemplateComparison", "diff"], ["project_oidc", "OidcManifest", "project_oidc"],
    ["project_tenant", "Tenant", "provision"], ["project_tenant", "Tenant", "reprovision"]
  ].flat_map { |script, aggregate, verb| rows(script, "Deploy", aggregate, verb) }.freeze

  # QualityControl names each command by its aggregate where two aggregates share a verb
  # (`patch.open`, `improvement.open`, `angle.seed`, `target.seed`), and by the bare verb otherwise.
  # The table's launcher spellings (`open_patch`, `log_bug`) are the ADR's; the chapter answers to
  # the command's name. The `qa_*` scripts that are not commands of a ledger record (a tick, a
  # sweep, a seed) are queries answered by a port, since they read and write no record of their own.
  QUALITY_CONTROL = [
    rows("qa_tick", "QualityControl", "Sweep", "tick"),
    # `run` alone is the CI port's `Clearance.CI.Run`, so the query is asked for by name.
    rows("qa_sweep", "QualityControl", "Sweep", [{ "run" => "ask run" }]),
    rows("qa_sweep", "QualityControl", "Target", [{ "release" => "release" }]),
    rows("qa_pr_check", "QualityControl", "Clearance", "check_pull_requests"),
    rows("qa_open_pr", "QualityControl", "Patch", [{ "open" => "patch.open" }]),
    rows("qa_open_pr", "QualityControl", "Improvement", [{ "open" => "improvement.open" }]),
    rows("qa_log_bug", "QualityControl", "Bug", [{ "log" => "log" }]),
    rows("qa_seed_angles", "QualityControl", "Angle", [{ "seed" => "angle.seed" }]),
    rows("qa_seed_targets", "QualityControl", "Target", [{ "seed" => "target.seed" }]),
    rows("qa_generated_domains", "QualityControl", "Target", "check_generated_domains"),
    rows("qa_mine_combinations", "QualityControl", "Target", "mine_combinations"),
    rows("qa_domain_novelty", "QualityControl", "Target", "judge_novelty"),
    rows("qa_discover_external_domains", "QualityControl", "Target", "discover_external_domains"),
    rows("qa_postgres_migrate", "QualityControl", "Sweep", "migrate_ledger_from_heki"),
    rows("qa_postgres_role", "QualityControl", "Sweep", "create_ledger_role"),
    rows("qa_concurrency_racer", "QualityControl", "Sweep", "race")
  ].flatten.freeze

  ALL_ROWS = (CUSTODIAN + CODEBASE + DEPLOY + QUALITY_CONTROL).freeze

  # The table gives `console` and `mcp` as the launcher's names for OpenConsole and ServeMcp.
  LAUNCHER_HELP_NAME = { "open_console" => "console", "serve_mcp" => "mcp" }.freeze

  # Commands whose verb the chapter does not answer on its own: `Race` runs only as a child
  # process the ProcessPool starts, so the table gives it no launcher form.
  NOT_USER_FACING = %w[race].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
    @bluebooks = Hash.new { |cache, chapter| cache[chapter] = @hecks.registry.bluebook(chapter) }
  end

  def declared?(row)
    aggregate = @bluebooks[row.chapter == "Hecks" ? "Hecks" : row.chapter].aggregate(row.aggregate)
    return false unless aggregate

    aggregate.commands.map(&:hecks_name).include?(row.name) || !aggregate.query(row.name).nil?
  end

  # A QualityControl row's help says it is that row's own command or query, so a verb another
  # aggregate also answers to (`run`) cannot pass for it.
  def names_its_own_command?(row, out)
    row.chapter != "QualityControl" || out.include?("QualityControl::#{row.aggregate}.#{row.name}")
  end

  def answers_help?(row)
    out, status = Hecks::Facade::CliRunner.call(runtime: @hecks, argv: [*row.argv, "--help"], program: "hecks")
    status.zero? && out.start_with?(LAUNCHER_HELP_NAME.fetch(row.verb, row.help_name)) && names_its_own_command?(row, out)
  end

  ALL_ROWS.each do |row|
    it "answers #{row.script} as #{row.chapter}: #{row.aggregate}.#{row.name}, `hecks #{row.argv.join(' ')}`" do
      pending(row.gap) if row.gap

      expect(declared?(row)).to be(true), "#{row.aggregate}.#{row.name} is not declared in #{row.chapter}"
      next if NOT_USER_FACING.include?(row.verb)

      expect(answers_help?(row)).to be(true), "`hecks #{row.argv.join(' ')} --help` does not answer"
    end
  end

  it "accounts for every script bin/ holds, and names no script bin/ lacks" do
    bin = File.join(InMemoryDomain::ROOT, "bin")
    skip "bin/ is gone" unless Dir.exist?(bin)

    listed = ALL_ROWS.map(&:script).uniq - ["(new)"]
    held = Dir.children(bin).reject { |entry| File.directory?(File.join(bin, entry)) }

    expect(held - listed).to eq([]), "scripts with no row: #{(held - listed).join(', ')}"
    expect(listed - held).to eq([]), "rows for scripts bin/ lacks: #{(listed - held).join(', ')}"
  end

  it "lists each command once" do
    keys = ALL_ROWS.map { |row| [row.chapter, row.aggregate, row.name, row.script] }

    expect(keys.uniq.size).to eq(keys.size)
    expect(ALL_ROWS.reject(&:gap).map(&:argv).uniq.size).to eq(ALL_ROWS.reject(&:gap).size)
  end

  it "has no gap left: every row's command is declared" do
    expect(ALL_ROWS.select(&:gap).map(&:script)).to eq([])
  end
end
