require "spec_helper"

# Projections::Statements turns declared facts into plain-English sentences, never inventing one.
RSpec.describe "the domain's own English statements" do
  PIZZAS_STATEMENTS = [
    "Each order holds a list of toppings.",
    "A pizza is named.",
    "A price is never negative.",
    "A customer is named.",
    "A topping is named.",
    "A topping name is more than whitespace.",
    "An amount is positive.",
    "An order starts out available.",
    "Purchasing an order moves it from available to sold.",
    "Creating a pizza is done by the chef.",
    "Adding a topping is done by the chef.",
    "Adding a topping requires: the order is available.",
    "Adding a topping requires: at most 10 toppings.",
    "Purchasing an order is done by the customer.",
    "Purchasing an order requires: a pizza needs at least one topping.",
    "Purchasing an order requires: a payment was actually made.",
    "Purchasing an order requires: the payment covers the price."
  ].freeze

  BANKING_RELATIONSHIPS = ["Each account belongs to one customer.", "Each transfer has one source account.",
                           "Each transfer has one destination account.",
                           "Each card payment can be disputed by one customer.",
                           "Each account holds its ledger, a list of ledger entries."].freeze

  def boot_banking
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry
  end

  let(:pizzas_chapter)     { boot_in_memory.registry.bluebook("Pizzas") }
  let(:banking_chapter)    { boot_banking.bluebook("Banking") }
  let(:banking_statements) { Hecks::Projector.call(:statements, bluebook: banking_chapter) }

  it "states Pizzas' list, invariants, lifecycle and every command rule, rules verbatim" do
    expect(Hecks::Projector.call(:statements, bluebook: pizzas_chapter)).to eq(PIZZAS_STATEMENTS)
  end

  it "is reachable the same way every projection already is, with no bespoke wiring" do
    # `boot_in_memory` (via `pizzas_chapter`) installs the top-level Pizzas constant.
    expected = Hecks::Projector.call(:statements, bluebook: pizzas_chapter)
    expect(Pizzas.project(Hecks::Projections::Statements)).to eq(expected)
  end

  # Regression: output read "A ATMCard" and "a Account".
  it "never gets the indefinite article wrong, anywhere in a real, richly-relational domain" do
    wrong_article = banking_statements.grep(/\b[Aa] (account|ATM card|external transfer|onboarding case)\b/)
    expect(wrong_article).to be_empty, "wrong article (should be \"an\"): #{wrong_article.join(", ")}"
  end

  # A tagged `one_of` reference (ADR 0127) is a relationship too.
  it "draws one relationship statement per reference and list attribute in banking" do
    related = ->(a) { a.reference? || a.list? || Hecks::Bluebook::OneOfUnion.union?(a) }
    attributes = banking_chapter.aggregates.flat_map { |a| [a, *a.entities] }
                                .flat_map { |h| h.attributes.select(&related) }
    expect(banking_statements.grep(/\AEach /).size).to eq(attributes.size)
  end

  it "says what each reference is, by its name and cardinality, never just that it references", :aggregate_failures do
    expect(banking_statements).to include(*BANKING_RELATIONSHIPS)
    expect(banking_statements.grep(/references/)).to be_empty
  end

  it "states each move, merging the states a command moves from", :aggregate_failures do
    expect(banking_statements).to include("Closing an account moves it from open or frozen to closed.",
                                          "Rejecting a dispute moves the card payment from disputed to captured.",
                                          "Retrying a scheduled payment keeps it failed.",
                                          "Marking a transfer debited moves it from requested to debited.")
  end

  it "states what a command guarantees afterwards, and who does it", :aggregate_failures do
    expect(banking_statements).to include("After debiting an account: the balance fell by exactly the amount.",
                                          "Debiting an account is done by the teller.",
                                          "Withdrawing from an ATM card requires: the ATM card is active.")
  end

  it "states a real, known invariant capitalized and punctuated, unparaphrased" do
    expect(banking_statements).to include("A retry limit is positive.")
  end

  it "states nothing for an attribute that is neither a list nor a relationship" do
    order = pizzas_chapter.aggregates.find { |a| a.hecks_name == "Order" }
    scalar_attribute = order.attributes.find { |a| a.name == :name }
    expect(Hecks::Projections::Statements.attribute_statement(order, scalar_attribute)).to be_nil
  end
end
