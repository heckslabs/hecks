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
  CODEBASE_ROWS = [
    CodebaseRow.new(script: "project_model",           aggregate: "LanguageRun", name: "ProjectModel",           verb: "project_model"),
    CodebaseRow.new(script: "project_vocabulary",      aggregate: "LanguageRun", name: "ProjectVocabulary",      verb: "project_vocabulary"),
    CodebaseRow.new(script: "project_rust_vocabulary", aggregate: "LanguageRun", name: "ProjectRustVocabulary",  verb: "project_rust_vocabulary"),
    CodebaseRow.new(script: "project_refusal_wording", aggregate: "LanguageRun", name: "ProjectRefusalWording",  verb: "project_refusal_wording",
                    renamed: "the table calls it the same command under a second name; it is a second command " \
                             "that carries out the same operation, since a verb has one name"),
    CodebaseRow.new(script: "project_reserved_names",  aggregate: "LanguageRun", name: "ProjectReservedNames",   verb: "project_reserved_names"),
    CodebaseRow.new(script: "project_parser_table",    aggregate: "LanguageRun", name: "ProjectParserTable",     verb: "project_parser_table"),
    CodebaseRow.new(script: "project_bootstrap_table", aggregate: "LanguageRun", name: "ProjectBootstrapTable",  verb: "project_bootstrap_table"),
    CodebaseRow.new(script: "project_field_hints",     aggregate: "LanguageRun", name: "ProjectFieldHints",      verb: "project_field_hints"),
    CodebaseRow.new(script: "expression_projection",   aggregate: "LanguageRun", name: "ProjectExpressionTables", verb: "project_expression_tables"),
    CodebaseRow.new(script: "reference",               aggregate: "LanguageRun", name: "ProjectReference",       verb: "project_reference"),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "WordStatus",             verb: "word_status", query: true),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "Propose",                verb: "propose",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "Admit",                  verb: "admit",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "Deprecate",              verb: "deprecate",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "Retire",                 verb: "retire",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "Rename",                 verb: "rename",
                    args: %w[word context=Aggregate new_name=other]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "ProposeArgument",        verb: "propose_argument",
                    args: %w[word context=Aggregate kind=text]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "AdmitArgument",          verb: "admit_argument",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "DeprecateArgument",      verb: "deprecate_argument",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "evolve",                  aggregate: "LanguageRun", name: "RetireArgument",         verb: "retire_argument",
                    args: %w[word context=Aggregate]),
    CodebaseRow.new(script: "project_kernel_capabilities", aggregate: "KernelRun", name: "ProjectKernelCapabilities",
                    verb: "project_kernel_capabilities",
                    renamed: "the table names the command ProjectCapabilities; the verb it gives is " \
                             "project_kernel_capabilities, and a launcher verb is the command's snake name"),
    CodebaseRow.new(script: "rust_kernel_coverage",    aggregate: "KernelRun", name: "MeasureKernelCoverage",
                    verb: "measure_kernel_coverage",
                    renamed: "the table names the command MeasureCoverage; the verb it gives is " \
                             "measure_kernel_coverage"),
    CodebaseRow.new(script: "check_engine_agreement",  aggregate: "ConformanceRun", name: "CheckEngineAgreement",
                    verb: "check_engine_agreement"),
    CodebaseRow.new(script: "doc_coverage",            aggregate: "ConformanceRun", name: "MeasureDocCoverage",
                    verb: "measure_doc_coverage"),
    CodebaseRow.new(script: "argument_gate_matrix",    aggregate: "ConformanceRun", name: "ArgumentGateMatrix",
                    verb: "argument_gate_matrix")
  ].freeze

  # The aggregates this spec covers so far, each of which must hold at least one row.
  CODEBASE_AGGREGATES = %w[LanguageRun KernelRun ConformanceRun].freeze

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
      expect(accept.givens.map(&:to_s).join).to include("needs a hecks checkout")
    end
  end
end
