require "spec_helper"

# Anti-drift gate: bootstrap_table.rb must equal a fresh projection of the Keyword rows.
# It is checked in because WordGate and RuleReference read it before the grammar exists.
RSpec.describe "the generated bootstrap table" do
  let(:table) { Hecks::Bluebook::DSL::BootstrapTable }

  def committed_table = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/bluebook/dsl/bootstrap_table.rb"))

  def projected_table
    Hecks::Projector.call(:bootstrap_table, bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook"))
  end

  it "is exactly what hecks project_bootstrap_table would regenerate right now" do
    expect(projected_table).to eq(committed_table),
                               "bootstrap_table.rb has drifted from the Keyword rows — run hecks project_bootstrap_table"
  end

  it "needs no part of the framework loaded to be read" do
    expect(committed_table).not_to match(/^\s*require/)
  end

  describe "the fallbacks read the table rather than repeating it" do
    it "WordGate's calls fallback is the table's own Hash" do
      expect(Hecks::Bluebook::DSL::GenericDispatch::BOOTSTRAP_CALLS_FALLBACK).to equal(table::CALLS)
    end

    it "RuleReference's resolution fallback is the table's own Hash" do
      expect(Hecks::Bluebook::DSL::RuleReference::BOOTSTRAP_FALLBACK).to equal(table::RESOLVES)
    end
  end

  # A `calls:` typo in a KeywordSeed row would otherwise surface only as a
  # NoMethodError the first time a bootstrap chapter used that word.
  # `Module#name` bound directly: some loaded modules (rubocop-ast's NodePattern
  # sets) override `name` to take an argument.
  def hecks_modules
    module_name = Module.instance_method(:name)
    ObjectSpace.each_object(Module).select { |mod| module_name.bind_call(mod)&.start_with?("Hecks::") }
  end

  it "names, in every calls row, a method some DSL module really defines" do
    modules = hecks_modules
    unanswered = table::CALLS.values.uniq.reject do |target|
      modules.any? { |mod| mod.method_defined?(target) || mod.private_method_defined?(target) }
    end

    expect(unanswered).to eq([])
  end

  # `uniq` because an overloaded word (`identified_by`, `transition`, `dispatch`)
  # has one row per argument shape, all naming the same method.
  it "carries every live calls: row the grammar declares" do
    live = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
                                                     .reject { |row| row[:status] == "retired" || row[:calls].to_s.empty? }

    expect(table::CALLS.keys).to match_array(live.map { |row| [row[:context], row[:word]] }.uniq)
  end

  CONFLICTING_ROWS = [
    { context: "Aggregate", word: "given", calls: "given_impl", status: "admitted" },
    { context: "Aggregate", word: "given", calls: "other_impl", status: "admitted" }
  ].freeze

  it "refuses two rows for one word that name different methods, rather than keeping whichever came last" do
    expect { Hecks::Projections::BootstrapTable.calls(CONFLICTING_ROWS) }
      .to raise_error(Hecks::Projections::BootstrapTable::Conflict, /Aggregate.*given.*given_impl.*other_impl/)
  end
end
