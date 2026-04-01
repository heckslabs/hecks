require "spec_helper"

RSpec.describe Hecks::DomainGlossary do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String
        attribute :toppings, list_of("Topping")

        value_object "Topping" do
          attribute :name, String
          attribute :amount, Integer
          invariant "amount must be positive" do
            amount > 0
          end
        end

        validation :name, presence: true

        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
        end

        query "Classics" do
          where(style: "Classic")
        end

        policy "NotifyKitchen" do
          on "CreatedPizza"
          trigger "CreatePizza"
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        policy "SendConfirmation" do
          on "PlacedOrder"
          trigger "PlaceOrder"
          async true
        end
      end
    end
  end

  subject(:glossary) { described_class.new(domain) }
  let(:lines) { glossary.generate }
  let(:text) { lines.join("\n") }

  it "includes the domain name" do
    expect(text).to include("Pizzas Domain Glossary")
  end

  it "describes scalar attributes" do
    expect(text).to include("A Pizza has a name (String).")
  end

  it "describes list attributes with has many" do
    expect(text).to include("A Pizza has many Toppings.")
  end

  it "describes references in relationships section" do
    expect(text).to include("An Order references a Pizza.")
  end

  it "uses correct articles for vowel-starting names" do
    expect(text).to include("An Order")
    expect(text).not_to include("A Order")
  end

  it "describes value objects as part of their aggregate" do
    expect(text).to include("A Topping is part of a Pizza.")
  end

  it "includes value object attributes" do
    expect(text).to include("A Topping has an amount (Integer).")
  end

  it "includes invariant rules" do
    expect(text).to include("amount must be positive. (invariant)")
  end

  it "describes commands as actions" do
    expect(text).to include("You can create a Pizza with name and style.")
  end

  it "describes queries as lookups" do
    expect(text).to include("You can look up Pizzas by classics. (query)")
  end

  it "describes validations as requirements" do
    expect(text).to include("A Pizza must have a name. (validation)")
  end

  it "describes policies as reactions" do
    expect(text).to include("the system will create Pizza")
    expect(text).to include("(policy)")
  end

  it "marks async policies" do
    expect(text).to include("(asynchronously)")
  end

  it "includes a relationships section" do
    expect(text).to include("Relationships")
    expect(text).to include("An Order references a Pizza.")
  end

  describe "#print" do
    it "outputs to stdout" do
      expect { glossary.print }.to output(/Pizzas Domain Glossary/).to_stdout
    end
  end

  describe "Domain#glossary" do
    it "is a convenience method" do
      expect { domain.glossary }.to output(/Pizzas Domain Glossary/).to_stdout
    end
  end

  describe "ubiquitous language section" do
    let(:domain) do
      Hecks.domain "Pizzas" do
        glossary do
          define "aggregate", as: "A cluster of domain objects treated as a unit"
          prefer "stakeholder", not: ["user", "person"], definition: "Anyone with a vested interest"
          prefer "topping", not: ["ingredient"]
        end

        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end
    end

    it "includes the Ubiquitous Language heading" do
      expect(text).to include("## Ubiquitous Language")
    end

    it "renders defined terms with definitions" do
      expect(text).to include("- **aggregate** -- A cluster of domain objects treated as a unit")
    end

    it "renders prefer terms with definitions and avoided words" do
      expect(text).to include("- **stakeholder** -- Anyone with a vested interest (avoid: user, person)")
    end

    it "renders prefer terms without definitions but with avoided words" do
      expect(text).to include("- **topping** (avoid: ingredient)")
    end
  end
end
