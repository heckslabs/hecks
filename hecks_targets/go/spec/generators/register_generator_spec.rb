require "spec_helper"
require "go_hecks"

RSpec.describe GoHecks::RegisterGenerator do
  let(:domain) do
    Hecks.domain("Pizzas") do
      aggregate("Pizza") do
        attribute :name, String
        command("CreatePizza") { attribute :name, String }
        command("UpdatePizza") { attribute :pizza, String; attribute :name, String }
      end

      aggregate("Order") do
        reference_to "Pizza"
        attribute :quantity, Integer
        command("PlaceOrder") { reference_to "Pizza"; attribute :quantity, Integer }
      end
    end
  end

  let(:generator) do
    described_class.new(domain, package: "domain", module_path: "pizzas_domain")
  end
  let(:output) { generator.generate }

  it "declares the correct package" do
    expect(output).to include("package domain")
  end

  it "imports the runtime package" do
    expect(output).to include('"pizzas_domain/runtime"')
  end

  it "defines an init function" do
    expect(output).to include("func init() {")
  end

  it "registers with the domain name" do
    expect(output).to include('Name:       "Pizzas"')
  end

  it "lists all aggregate names" do
    expect(output).to include('"Pizza"')
    expect(output).to include('"Order"')
    expect(output).to include("Aggregates:")
  end

  it "lists all command names" do
    expect(output).to include('"CreatePizza"')
    expect(output).to include('"UpdatePizza"')
    expect(output).to include('"PlaceOrder"')
    expect(output).to include("Commands:")
  end

  context "with subdomain package" do
    let(:generator) do
      described_class.new(domain, package: "pizzas", module_path: "multi_domain")
    end
    let(:output) { generator.generate }

    it "uses the subdomain package name" do
      expect(output).to include("package pizzas")
    end

    it "imports from the multi-domain module path" do
      expect(output).to include('"multi_domain/runtime"')
    end
  end

  context "with empty domain" do
    let(:empty_domain) do
      Hecks.domain("Empty") do
        aggregate("Thing") do
          attribute :name, String
        end
      end
    end

    let(:generator) do
      described_class.new(empty_domain, package: "domain", module_path: "empty_domain")
    end
    let(:output) { generator.generate }

    it "generates empty command slice" do
      expect(output).to include("Commands:   []string{}")
    end

    it "still lists aggregates" do
      expect(output).to include('"Thing"')
    end
  end
end
