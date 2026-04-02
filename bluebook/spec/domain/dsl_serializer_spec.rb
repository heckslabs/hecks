require "spec_helper"

RSpec.describe Hecks::DslSerializer do
  it "serializes aggregate definition: kwarg inline" do
    domain = Hecks.domain "Pizzas" do
      aggregate "Pizza", definition: "A customizable food item" do
        attribute :name, String
      end
    end

    source = described_class.new(domain).serialize
    expect(source).to include('aggregate "Pizza", definition: "A customizable food item"')
    expect(source).not_to include("description")
  end

  it "round-trips aggregate definition: through eval" do
    domain = Hecks.domain "Pizzas" do
      aggregate "Pizza", definition: "A customizable food item" do
        attribute :name, String
      end
    end

    source = described_class.new(domain).serialize
    restored = eval(source)
    expect(restored.aggregates.first.description).to eq("A customizable food item")
  end

  it "omits definition: kwarg when not set" do
    domain = Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
      end
    end

    source = described_class.new(domain).serialize
    expect(source).to include('aggregate "Pizza" do')
    expect(source).not_to include("definition:")
  end

  it "serializes a domain back to DSL source" do
    domain = Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String
        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
        end
      end
    end

    source = described_class.new(domain).serialize
    expect(source).to include('Hecks.domain "Pizzas"')
    expect(source).to include('aggregate "Pizza"')
    expect(source).to include('attribute :name, String')
    expect(source).to include('command "CreatePizza"')
  end

  it "round-trips through eval" do
    domain = Hecks.domain "RoundTrip" do
      aggregate "Thing" do
        attribute :name, String
        command "CreateThing" do
          attribute :name, String
        end
      end
    end

    source = described_class.new(domain).serialize
    restored = eval(source)
    expect(restored.name).to eq("RoundTrip")
    expect(restored.aggregates.first.name).to eq("Thing")
  end
end
