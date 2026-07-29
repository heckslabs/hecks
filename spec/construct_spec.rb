
require "spec_helper"

# A CONSTRUCT IS A RUBY CLASS, AND ITS BLUEBOOK NAME IS A FIELD BESIDE IT.
#
# Value objects have crossed over first: `ValueObjectBuilder` returns a subclass
# of `IR::ValueObject` rather than an instance of it, nested where the bluebook
# nests it. So `Pizzas::Pizza::Price` is a real constant, and Ruby's constant
# tree is the index — which is why `aggregate.value_object(name)` is on its way
# out rather than being reimplemented.
#
# The reason the declared name is carried separately, instead of `Class#name`
# being shortened to answer for it, is in this file as an assertion rather than
# an argument: three aggregates in banking each declare their own `Narrative`.
# Shorten `name` and all three answer "Narrative", with `inspect` disagreeing.
RSpec.describe "a construct's identity" do
  def registry_for(domain)
    Hecks.boot(File.join(InMemoryDomain::ROOT, domain)).registry
  end

  # Memoised per example ON PURPOSE. Every boot mints a fresh class graph and
  # repoints the top-level constant at the newest, so two boots in one example
  # yield two different `Price` classes — which is worth knowing and is not what
  # any of these examples are about.
  def pizza
    @pizza ||= registry_for("examples/pizzas").bluebook("Pizzas").aggregate("Pizza").ruby_class
  end

  it "spells an aggregate the way the aggregate already spelled itself" do
    # `Aggregate.fqn` predates the mixin and computes "#{domain}::#{ir.name}".
    # If these two ever disagree there are two identities for one construct,
    # which is the thing the invisible field exists to prevent.
    expect(pizza.hecks_fqn).to eq(pizza.fqn)
    expect(pizza.hecks_fqn).to eq("Pizzas::Pizza")
  end

  it "spells a value object the way the meta-domain already ids one" do
    # `MetaValidator::Judge#identify` mints "#{parent_id}.#{name}" for every
    # category below an aggregate. Same string, arrived at from the class graph
    # instead of from a walk — so a construct and the language's record OF that
    # construct need no translation between them.
    expect(pizza::Price.hecks_fqn).to eq("Pizzas::Pizza.Price")
  end

  it "leaves Class#name telling the truth about where the class lives" do
    expect(pizza::Price.name).to eq("Pizzas::Pizza::Price")
    expect(pizza::Price.hecks_name).to eq("Price")
  end

  it "reaches a value object as a nested constant, with no lookup at all" do
    expect(pizza.const_get(:Price)).to be(pizza::Price)
    expect(pizza::Price).to be_a(Class)
    expect(pizza::Price.attributes.map(&:name)).to eq([:cents])
  end

  it "keeps three same-named value objects distinguishable" do
    banking = registry_for("examples/banking").bluebook("Banking")
    owners  = %w[Account ATMCard Transfer]
    shapes  = owners.map { |name| banking.aggregate(name).ruby_class::Narrative }

    expect(shapes.uniq.size).to eq(3)
    expect(shapes.map(&:hecks_name)).to eq(%w[Narrative Narrative Narrative])
    expect(shapes.map(&:hecks_fqn)).to eq(
      ["Banking::Account.Narrative", "Banking::ATMCard.Narrative", "Banking::Transfer.Narrative"]
    )
  end
end
