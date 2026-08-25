require "spec_helper"

# Projections::Statements turns a domain's own declared facts into flat,
# plain-English sentences — see its own header for the "never invent a
# sentence" discipline this spec holds it to.
RSpec.describe "the domain's own English statements" do
  def boot_banking
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry
  end

  let(:pizzas_chapter)  { boot_in_memory.registry.bluebook("Pizzas") }
  let(:banking_chapter) { boot_banking.bluebook("Banking") }

  it "states exactly Pizzas' own declared list attribute and every invariant, verbatim" do
    expect(Hecks::Projector.call(:statements, bluebook: pizzas_chapter)).to eq([
                                                                                 "An Order has many toppings.",
                                                                                 "A pizza is named.",
                                                                                 "A price is never negative.",
                                                                                 "A customer is named.",
                                                                                 "A topping is named.",
                                                                                 "An amount is positive."
                                                                               ])
  end

  it "is reachable the same way every projection already is, with no bespoke wiring" do
    # `pizzas_chapter`'s own `boot_in_memory` already installs the real
    # top-level Pizzas constant (Facade::Surface.install, via
    # Loader.bind_runtime) — referenced here for that side effect before
    # calling through it exactly as a real caller would.
    expected = Hecks::Projector.call(:statements, bluebook: pizzas_chapter)
    expect(Pizzas.project(Hecks::Projections::Statements)).to eq(expected)
  end

  # THE BUG THE EXAMPLE OUTPUT ACTUALLY HAD, caught by eye against real
  # banking output before this spec existed ("A ATMCard", "a Account") —
  # pinned here so it can't come back silently.
  it "never gets the indefinite article wrong, anywhere in a real, richly-relational domain" do
    statements = Hecks::Projector.call(:statements, bluebook: banking_chapter)
    wrong_article = statements.grep(/\bA (Account|ATMCard|ExternalTransfer|OnboardingCase|Onboarding)\b/)
    expect(wrong_article).to be_empty, "wrong article (should be \"An\"): #{wrong_article.join(', ')}"
  end

  it "draws one relationship statement per real reference/belongs_to/has_many/has_one attribute in banking" do
    statements = Hecks::Projector.call(:statements, bluebook: banking_chapter)
    holder_relationship_attributes = banking_chapter.aggregates.flat_map { |a| [a, *a.entities] }
                                                    .flat_map { |h| h.attributes.select(&:reference?) }

    relationship_statements = statements.grep(/\b(has a|has an|belongs to|references)\b/)
    expect(relationship_statements.size).to eq(holder_relationship_attributes.size)
  end

  it "states a real, known invariant capitalized and punctuated, unparaphrased" do
    statements = Hecks::Projector.call(:statements, bluebook: banking_chapter)
    expect(statements).to include("A retry limit is positive.")
  end

  it "states nothing for an attribute that is neither a list nor a relationship" do
    order = pizzas_chapter.aggregates.find { |a| a.hecks_name == "Order" }
    scalar_attribute = order.attributes.find { |a| a.name == :name }
    expect(Hecks::Projections::Statements.attribute_statement(order, scalar_attribute)).to be_nil
  end
end
