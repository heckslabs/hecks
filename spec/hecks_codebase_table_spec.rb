require "spec_helper"
require "json"
require "tmpdir"

# ADR 0080, section 7: the Codebase rows of the command table resolve in the launcher, and every
# one refuses outside a hecks checkout. Each row names a script, the aggregate and command (or
# query) that replaces it, and the verb that answers it; this spec lists the rows, checks the
# command or query is declared, that its verb answers `--help`, and that run against a tree with no
# `hecks.gemspec` beside `lib/` it answers "needs a hecks checkout" instead of touching the tree.
# Where the domain spells a row differently from the ADR, the row says so in `renamed`.
RSpec.describe "the Codebase rows of the ADR command table" do
  # `args` are the words a run of the verb needs beyond its run key; `query` marks a pure read.
  CodebaseRow = Struct.new(:script, :aggregate, :name, :verb, :args, :query, :renamed, keyword_init: true)

  # The aggregates are named for the run, as ModelCheckRun is: the table's Language, Kernel,
  # Conformance, Regeneration and Style are concerns, and some share a name with a module the gem
  # already owns.
  # Each row: script, aggregate, command or query, verb, and what the row needs beyond a run key.
  CODEBASE_ROWS = [
    ["project_model", "LanguageRun", "ProjectModel", "project_model"],
    ["project_vocabulary", "LanguageRun", "ProjectVocabulary", "project_vocabulary"],
    ["project_rust_vocabulary", "LanguageRun", "ProjectRustVocabulary", "project_rust_vocabulary"],
    ["project_refusal_wording", "LanguageRun", "ProjectRefusalWording", "project_refusal_wording",
     { renamed: "the table calls it the same command under a second name; it is a second command " \
                "that carries out the same operation, since a verb has one name" }],
    ["project_reserved_names", "LanguageRun", "ProjectReservedNames", "project_reserved_names"],
    ["project_parser_table", "LanguageRun", "ProjectParserTable", "project_parser_table"],
    ["project_bootstrap_table", "LanguageRun", "ProjectBootstrapTable", "project_bootstrap_table"],
    ["project_field_hints", "LanguageRun", "ProjectFieldHints", "project_field_hints"],
    ["expression_projection", "LanguageRun", "ProjectExpressionTables", "project_expression_tables"],
    ["reference", "LanguageRun", "ProjectReference", "project_reference"],
    ["evolve", "LanguageRun", "WordStatus", "word_status", { query: true }],
    ["evolve", "LanguageRun", "Propose", "propose", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "Admit", "admit", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "Deprecate", "deprecate", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "Retire", "retire", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "Rename", "rename", { args: %w[word context=Aggregate new_name=other] }],
    ["evolve", "LanguageRun", "ProposeArgument", "propose_argument",
     { args: %w[word context=Aggregate kind=text] }],
    ["evolve", "LanguageRun", "AdmitArgument", "admit_argument", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "DeprecateArgument", "deprecate_argument", { args: %w[word context=Aggregate] }],
    ["evolve", "LanguageRun", "RetireArgument", "retire_argument", { args: %w[word context=Aggregate] }],
    ["project_kernel_capabilities", "KernelRun", "ProjectKernelCapabilities", "project_kernel_capabilities",
     { renamed: "the table names the command ProjectCapabilities; the verb it gives is " \
                "project_kernel_capabilities, and a launcher verb is the command's snake name" }],
    ["rust_kernel_coverage", "KernelRun", "MeasureKernelCoverage", "measure_kernel_coverage",
     { renamed: "the table names the command MeasureCoverage; the verb it gives is " \
                "measure_kernel_coverage" }],
    ["check_engine_agreement", "ConformanceRun", "CheckEngineAgreement", "check_engine_agreement"],
    ["doc_coverage", "ConformanceRun", "MeasureDocCoverage", "measure_doc_coverage"],
    ["argument_gate_matrix", "ConformanceRun", "ArgumentGateMatrix", "argument_gate_matrix"],
    ["regen_codegen_domains", "RegenerationRun", "RegenerateCorpus", "regenerate_corpus"],
    ["standardize_comments", "StyleRun", "ReportComments", "report_comments",
     { args: %w[paths=lib], query: true }],
    ["standardize_comments", "StyleRun", "CheckComments", "check_comments", { args: %w[paths=lib] }],
    ["standardize_comments", "StyleRun", "FixComments", "fix_comments", { args: %w[paths=lib] }],
    ["standardize_comments", "StyleRun", "WriteCommentBaseline", "write_comment_baseline"],
    ["standardize_comments", "StyleRun", "CheckCommentsUnchanged", "check_comments_unchanged",
     { args: %w[ref=main] }],
    ["standardize_comments_rust", "StyleRun", "ReportRustComments", "report_rust_comments",
     { args: %w[paths=rust], query: true }],
    ["standardize_comments_rust", "StyleRun", "CheckRustComments", "check_rust_comments",
     { args: %w[paths=rust] }],
    ["standardize_comments_rust", "StyleRun", "FixRustComments", "fix_rust_comments", { args: %w[paths=rust] }],
    ["canonicalise", "StyleRun", "Canonicalise", "canonicalise", { args: %w[doc.json] }],
    ["codemod_hoist_local_givens", "CodemodRun", "HoistLocalGivens", "hoist_local_givens"],
    ["codemod_implicit_append_fields", "CodemodRun", "DropImplicitAppendFields", "drop_implicit_append_fields"],
    ["rspec_shard_files", "TestSuiteRun", "ShardSpecs", "shard_specs", { args: %w[group=1 groups=2], query: true }],
    ["rspec_io_parallel_files", "TestSuiteRun", "ListIoParallelSpecs", "list_io_parallel_specs",
     { args: %w[exclude=x], query: true }],
    ["rspec_io_parallel_files", "TestSuiteRun", "WriteIoParallelSpecList", "write_io_parallel_spec_list",
     { args:    %w[exclude=x write=list.txt],
       renamed: "the table folds write= into the listing query; a query never writes, so writing the " \
                "committed list is its own confirmed command" }],
    ["refresh_rspec_runtime_baseline", "TestSuiteRun", "RefreshRuntimeBaseline", "refresh_runtime_baseline"],
    ["spec_example", "TestSuiteRun", "RunSpecExample", "run_spec_example",
     { args: %w[file=spec/a_spec.rb example=hello] }],
    ["stress_concurrency_specs", "TestSuiteRun", "StressConcurrency", "stress_concurrency"],
    ["regenerate_persistence_legacy_fixtures", "TestSuiteRun", "RegenerateLegacyFixtures",
     "regenerate_legacy_fixtures"],
    ["seed_semantics_corpus", "TestSuiteRun", "SeedSemanticsCorpus", "seed_semantics_corpus"],
    ["pattern-cases", "TestSuiteRun", "RecordPatternCases", "record_pattern_cases",
     { query: true, renamed: "the table lists it beside the commands; it prints JSON and writes " \
                             "nothing (the script's output is redirected by the caller), so it is a query" }],
    ["corpus", "CorpusRun", "RustDomains", "rust_domains", { query: true }],
    ["corpus", "CorpusRun", "RegenOrder", "regen_order", { query: true }],
    ["corpus", "CorpusRun", "CorpusRustCoverage", "corpus_rust_coverage",
     { query: true, renamed: "the table names the query RustCoverage; Build already has one, " \
                             "so it is CorpusRustCoverage, as the launcher column says" }],
    ["query_ir", "CorpusRun", "IrConstructs", "ir_constructs", { query: true }],
    ["query_ir", "CorpusRun", "IrDuplicates", "ir_duplicates", { query: true }],
    ["query_ir", "CorpusRun", "IrImpact", "ir_impact", { args: %w[name=Entity field=given], query: true }],
    ["hecks_query_ir_mcp", "CorpusRun", "ServeQueryIrMcp", "serve_query_ir_mcp"],
    ["present", "CorpusRun", "Present", "present"],
    ["release", "PublishingRun", "Publish", "publish"],
    ["release_gem", "PublishingRun", "PublishGem", "publish_gem"]
  ].map do |script, aggregate, name, verb, extra|
    CodebaseRow.new(script: script, aggregate: aggregate, name: name, verb: verb, **(extra || {}))
  end.freeze

  # The aggregates this spec covers so far, each of which must hold at least one row.
  CODEBASE_AGGREGATES = %w[LanguageRun KernelRun ConformanceRun RegenerationRun StyleRun CodemodRun
                           TestSuiteRun CorpusRun PublishingRun].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
    @bluebook = @hecks.registry.bluebook("Hecks")
  end

  after { Hecks::Adapters::Codebase::Tree.root = nil }

  def declared?(row)
    aggregate = @bluebook.aggregate(row.aggregate)
    return false unless aggregate

    !aggregate.query(row.name).nil? || aggregate.commands.map(&:hecks_name).include?(row.name)
  end

  def launch(argv)
    Hecks::Facade::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  CODEBASE_ROWS.each do |row|
    it "answers #{row.script} as #{row.aggregate}.#{row.name}, `hecks #{row.verb}`" do
      expect(declared?(row)).to be(true), "#{row.aggregate}.#{row.name} is not declared in the Hecks domain"

      out, status = launch([row.verb, "--help"])

      expect(status).to eq(0)
      expect(out).to start_with(row.verb)
    end

    it "refuses `hecks #{row.verb}` outside a hecks checkout" do
      Dir.mktmpdir("not_a_checkout") do |dir|
        Dir.mkdir(File.join(dir, "lib"))
        Hecks::Adapters::Codebase::Tree.root = dir

        argv = [row.verb, *row.args, ("run=outside-#{row.verb}" unless row.query)].compact
        out, status = launch(argv)

        expect(out).to include("needs a hecks checkout")
        expect(status).to eq(row.query ? 1 : 0)
        expect(out).not_to include('"status": "completed"')
      end
    end
  end

  it "leaves a run the checkout rule refused as a faulted record that the aggregate's query lists" do
    Dir.mktmpdir("not_a_checkout") do |dir|
      Dir.mkdir(File.join(dir, "lib"))
      Hecks::Adapters::Codebase::Tree.root = dir

      out, status = launch(["project_vocabulary", "run=refused-1", "--wait"])
      row = JSON.parse(out).fetch("state")

      expect(status).to eq(1)
      expect(row.fetch("status")).to eq("faulted")
      expect(row.dig("refusal", "value")).to include("needs a hecks checkout")
      expect(JSON.parse(launch(["language_faulted"]).first).map { |run| run.dig("run", "value") })
        .to include("refused-1")
    end
  end

  %w[publish publish_gem].each do |verb|
    it "leaves `hecks #{verb}` outside a checkout as a faulted run that publishing_faulted lists" do
      Dir.mktmpdir("not_a_checkout") do |dir|
        Dir.mkdir(File.join(dir, "lib"))
        Hecks::Adapters::Codebase::Tree.root = dir

        out, status = launch([verb, "run=refused-#{verb}", "--wait"])

        expect(status).to eq(1)
        expect(JSON.parse(out).dig("state", "status")).to eq("faulted")
        expect(JSON.parse(launch(["publishing_faulted"]).first).map { |run| run.dig("run", "value") })
          .to include("refused-#{verb}")
      end
    end
  end

  it "lists every command of the table once, and gives each aggregate at least one row" do
    expect(CODEBASE_ROWS.map { |row| [row.aggregate, row.name] }.uniq.size).to eq(CODEBASE_ROWS.size)
    expect(CODEBASE_ROWS.select(&:renamed).map(&:renamed)).to all(be_a(String))
    expect(CODEBASE_ROWS.map(&:verb).uniq.size).to eq(CODEBASE_ROWS.size)
    expect(CODEBASE_AGGREGATES - CODEBASE_ROWS.map(&:aggregate)).to be_empty
    expect(CODEBASE_ROWS.map(&:aggregate) - CODEBASE_AGGREGATES).to be_empty
  end

  it "guards every command of every Codebase aggregate with the one checkout rule" do
    codebase = CODEBASE_AGGREGATES.map { |name| @bluebook.aggregate(name) }
    codebase.each do |aggregate|
      accept = aggregate.commands.find { |command| command.hecks_name == "Accept" }

      expect(accept).not_to be_nil, "#{aggregate.hecks_name} has no Accept"
      expect(accept.givens.join).to include("needs a hecks checkout")
    end
  end
end
