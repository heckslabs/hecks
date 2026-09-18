require "spec_helper"

# THE ANTI-DRIFT GATE for lib/hecks/bluebook/dsl/bootstrap_table.rb — the
# shape spec/vocabulary_table_spec.rb uses for lib/hecks/vocabulary.rb:
# regenerate in memory from the language's own Keyword rows and refuse a
# diff.
#
# WHY IT IS CHECKED IN AT ALL: `WordGate#method_missing` and
# `RuleReference#lookup` read it while `MetaValidator.bootstrapping?` —
# before the grammar table it is projected from exists. Built at boot, it
# would need itself to have been built already.
RSpec.describe "the generated bootstrap table" do
  let(:table) { Hecks::Bluebook::DSL::BootstrapTable }

  it "is exactly what bin/project_bootstrap_table would regenerate right now" do
    committed = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/bluebook/dsl/bootstrap_table.rb"))

    projected = Hecks::Projector.call(
      :bootstrap_table,
      bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    )

    expect(projected).to eq(committed),
                         "bootstrap_table.rb has drifted from the Keyword rows — run bin/project_bootstrap_table"
  end

  it "needs no part of the framework loaded to be read" do
    source = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/bluebook/dsl/bootstrap_table.rb"))

    expect(source).not_to match(/^\s*require/)
  end

  describe "the fallbacks read the table rather than repeating it" do
    it "WordGate's calls fallback is the table's own Hash" do
      expect(Hecks::Bluebook::DSL::GenericDispatch::BOOTSTRAP_CALLS_FALLBACK).to equal(table::CALLS)
    end

    it "RuleReference's resolution fallback is the table's own Hash" do
      expect(Hecks::Bluebook::DSL::RuleReference::BOOTSTRAP_FALLBACK).to equal(table::RESOLVES)
    end
  end

  # THE DESTINATION CHECK — a fallback row is only worth carrying if the
  # method it names is one some builder actually answers. A `calls:` typo
  # in a KeywordSeed row would otherwise surface only as a NoMethodError
  # the first time a bootstrap chapter used that word.
  it "names, in every calls row, a method some DSL module really defines" do
    # `Module#name` bound directly: some loaded modules (rubocop-ast's
    # NodePattern sets) override `name` to take an argument, and which of
    # them are loaded depends on what else ran in the process.
    module_name = Module.instance_method(:name)
    modules = ObjectSpace.each_object(Module).select { |mod| module_name.bind_call(mod)&.start_with?("Hecks::") }

    unanswered = table::CALLS.values.uniq.reject do |target|
      modules.any? { |mod| mod.method_defined?(target) || mod.private_method_defined?(target) }
    end

    expect(unanswered).to eq([])
  end

  # Every live row, not the subset a bootstrap chapter happened to call —
  # the hand-kept version carried 48 of these and silently omitted the rest.
  # `uniq` because an overloaded word (`identified_by`, `transition`,
  # `dispatch`) has one row per argument shape, all naming the same method.
  it "carries every live calls: row the grammar declares" do
    live = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
                                                     .reject { |row| row[:status] == "retired" || row[:calls].to_s.empty? }

    expect(table::CALLS.keys).to match_array(live.map { |row| [row[:context], row[:word]] }.uniq)
  end

  it "refuses two rows for one word that name different methods, rather than keeping whichever came last" do
    rows = [
      { context: "Aggregate", word: "given", calls: "given_impl", status: "admitted" },
      { context: "Aggregate", word: "given", calls: "other_impl", status: "admitted" }
    ]

    expect { Hecks::Projections::BootstrapTable.calls(rows) }
      .to raise_error(Hecks::Projections::BootstrapTable::Conflict, /Aggregate.*given.*given_impl.*other_impl/)
  end
end
