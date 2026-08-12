require "spec_helper"

# THE ANTI-DRIFT GATE for lib/hecksagain/vocabulary.rb — the same shape
# spec/parser_table_spec.rb uses for the Rust parser's keyword table:
# regenerate in memory from the language's own declaration and refuse a
# diff, so a checked-in artifact that stopped matching its source fails
# the ordinary suite rather than the next person to read it.
#
# WHY THE TABLE IS CHECKED IN AT ALL, rather than built at boot: several
# of these sets are read WHILE A BLUEBOOK IS BEING PARSED
# (`Attribute::PRIMITIVES` is consulted by the DSL itself). A table built
# from the judged grammar at load time would need the framework to have
# loaded before the framework could load.
RSpec.describe "the generated vocabulary table" do
  it "is exactly what bin/project_vocabulary would regenerate right now" do
    committed = File.read(File.join(InMemoryDomain::ROOT, "lib/hecksagain/vocabulary.rb"))

    expect(Hecksagain::VocabularyTable.render).to eq(committed),
      "lib/hecksagain/vocabulary.rb has drifted from vocabulary.bluebook — run bin/project_vocabulary"
  end

  # The point of generating rather than gating. spec/vocabulary_conformance_spec
  # holds each Ruby constant equal to the language; this proves there is
  # no longer a second thing to hold equal — the constant IS the table.
  describe "the constants read the table rather than repeating it" do
    {
      "Primitive"             => -> { Hecksagain::Bluebook::Attribute::PRIMITIVES },
      "SignTest"              => -> { Hecksagain::Bluebook::Expression::Resolver::SIGN_TESTS },
      "ToStringType"          => -> { Hecksagain::Bluebook::Expression::Resolver::TO_STRING_TYPES },
      "SizedType"             => -> { Hecksagain::Bluebook::Expression::Resolver::SIZED_TYPES },
      "IncludeHaystack"       => -> { Hecksagain::Bluebook::Expression::Evaluator::INCLUDE_HAYSTACKS },
      "NormalisationStrategy" => -> { Hecksagain::Bluebook::Expression::CanonicalForm::STRATEGIES },
      "LoadOrder"             => -> { Hecksagain::Adapters::Folder::DOMAIN_ORDER }
    }.each do |vocabulary, live|
      it "#{vocabulary} is the table's own list, not a copy of it" do
        expect(live.call).to equal(Hecksagain::Vocabulary.fetch(vocabulary))
      end
    end

    # THE FOUR THAT LOOKED LIKE THEY COULD NOT BE DERIVED, and could.
    #
    # Each had a reason that did not survive being written down:
    # DOMAIN_REFUSALS "maps to classes rather than names" (one const_get),
    # REFUSED "is a single constant, not a set" (Trigger declares exactly
    # it), and the two DISPATCH_ORDERs "name methods" — which is true, and
    # is why a SEPARATE gate already checks every declared step resolves to
    # a real handler. Naming them here and resolving them there are
    # different jobs.
    it "DomainRefusal resolves to the exception classes the module defines" do
      expect(Hecksagain::Runtime::DOMAIN_REFUSALS.map { |e| e.name.split("::").last })
        .to eq(Hecksagain::Vocabulary.fetch("DomainRefusal"))
    end

    it "Trigger is the language's own word for a refusal" do
      expect(Hecksagain::Bluebook::ProcessManager::REFUSED)
        .to eq(Hecksagain::Vocabulary.fetch("Trigger").first)
    end

    {
      "AggregateDispatchOrder" => -> { Hecksagain::Runtime::CommandInterpreter::DISPATCH_ORDER },
      "EntityDispatchOrder"    => -> { Hecksagain::Runtime::EntityInterpreter::DISPATCH_ORDER }
    }.each do |vocabulary, live|
      it "#{vocabulary} is the declared order, as symbols" do
        expect(live.call).to eq(Hecksagain::Vocabulary.symbols(vocabulary))
      end
    end

    # Symbols are a mapped copy rather than the same object, so this one
    # is held by value — the mapping is what the constant exists for.
    it "QueryComparator is the table's list, as symbols" do
      expect(Hecksagain::QuerySpecification::Common::COMPARATORS)
        .to eq(Hecksagain::Vocabulary.fetch("QueryComparator").map(&:to_sym))
    end
  end

  describe "the table itself" do
    # Several vocabularies carry MORE than a term — Comparison declares
    # the algebra each operator computes with. Rendering only the first
    # field of each row turned RefusalTemplate into thirty-nine
    # duplicated error names: well-formed, and meaningless.
    it "carries multi-field rows whole" do
      expect(Hecksagain::Vocabulary.rows("Comparison").first.keys)
        .to include("symbol", "compares_less_than", "compares_equal", "negated")
    end

    it "refuses a set the language does not declare, rather than answering nil" do
      expect { Hecksagain::Vocabulary.fetch("NoSuchVocabulary") }.to raise_error(KeyError)
    end

    it "needs no part of the framework loaded to be read" do
      table = File.read(File.join(InMemoryDomain::ROOT, "lib/hecksagain/vocabulary.rb"))

      expect(table).not_to match(/^\s*require/)
    end
  end
end
