require "spec_helper"

# Anti-drift gate for lib/hecks/vocabulary.rb, shaped like spec/parser_table_spec.rb: regenerate
# in memory from the language's declaration and refuse a diff.
# The table is checked in, not built at boot, because sets like `Attribute::PRIMITIVES` are read
# while a bluebook is parsed, before the framework could load.
RSpec.describe "the generated vocabulary table" do
  it "is exactly what bin/project_vocabulary would regenerate right now" do
    committed = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/vocabulary.rb"))

    projected = Hecks::Projector.call(
      :vocabulary,
      bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    )

    expect(projected).to eq(committed),
                         "lib/hecks/vocabulary.rb has drifted from vocabulary.bluebook — run bin/project_vocabulary"
  end

  # With the regeneration check above, this holds each Ruby constant equal to the language:
  # the constant is the table itself.
  describe "the constants read the table rather than repeating it" do
    {
      "Primitive"             => -> { Hecks::Bluebook::Attribute::PRIMITIVES },
      "SignTest"              => -> { Hecks::Bluebook::Expression::Resolver::SIGN_TESTS },
      "ToStringType"          => -> { Hecks::Bluebook::Expression::Resolver::TO_STRING_TYPES },
      "SizedType"             => -> { Hecks::Bluebook::Expression::Resolver::SIZED_TYPES },
      "IncludeHaystack"       => -> { Hecks::Bluebook::Expression::Evaluator::INCLUDE_HAYSTACKS },
      "NormalisationStrategy" => -> { Hecks::Bluebook::Expression::CanonicalForm::STRATEGIES },
      "LoadOrder"             => -> { Hecks::Adapters::Folder::DOMAIN_ORDER }
    }.each do |vocabulary, live|
      it "#{vocabulary} is the table's own list, not a copy of it" do
        expect(live.call).to equal(Hecks::Vocabulary.fetch(vocabulary))
      end
    end

    # Derivable despite appearances: DOMAIN_REFUSALS maps to classes (one const_get), REFUSED is
    # one constant Trigger declares, and a separate gate resolves the DISPATCH_ORDER methods.
    it "DomainRefusal resolves to the exception classes the module defines" do
      expect(Hecks::Runtime::DOMAIN_REFUSALS.map { |e| e.name.split("::").last })
        .to eq(Hecks::Vocabulary.fetch("DomainRefusal"))
    end

    it "Trigger is the language's own word for a refusal" do
      expect(Hecks::Bluebook::ProcessManager::REFUSED)
        .to eq(Hecks::Vocabulary.fetch("Trigger").first)
    end

    {
      "AggregateDispatchOrder" => -> { Hecks::Runtime::CommandInterpreter::DISPATCH_ORDER },
      "EntityDispatchOrder"    => -> { Hecks::Runtime::EntityInterpreter::DISPATCH_ORDER }
    }.each do |vocabulary, live|
      it "#{vocabulary} is the declared order, as symbols" do
        expect(live.call).to eq(Hecks::Vocabulary.symbols(vocabulary))
      end
    end

    # Symbols are a mapped copy, not the same object, so this one is held by value.
    it "QueryComparator is the table's list, as symbols" do
      expect(Hecks::QuerySpecification::Common::COMPARATORS)
        .to eq(Hecks::Vocabulary.fetch("QueryComparator").map(&:to_sym))
    end
  end

  describe "the table itself" do
    # Several vocabularies carry more than a term (Comparison declares each operator's algebra),
    # so rows must render whole; first-field-only rendering duplicated RefusalTemplate names.
    it "carries multi-field rows whole" do
      expect(Hecks::Vocabulary.rows("Comparison").first.keys)
        .to include("symbol", "compares_less_than", "compares_equal", "negated")
    end

    it "refuses a set the language does not declare, rather than answering nil" do
      expect { Hecks::Vocabulary.fetch("NoSuchVocabulary") }.to raise_error(KeyError)
    end

    it "needs no part of the framework loaded to be read" do
      table = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/vocabulary.rb"))

      expect(table).not_to match(/^\s*require/)
    end
  end
end
