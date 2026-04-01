require "spec_helper"

RSpec.describe "computed attributes" do
  describe "DSL parsing" do
    it "parses computed keyword and builds IR" do
      domain = Hecks.domain("RealEstate") do
        aggregate("Parcel") do
          attribute :area, Float
          attribute :density, Float
          computed :lot_size do
            area / 43560.0
          end
          command("CreateParcel") { attribute :area, Float; attribute :density, Float }
        end
      end

      agg = domain.aggregates.first
      expect(agg.computed_attributes.size).to eq(1)

      ca = agg.computed_attributes.first
      expect(ca.name).to eq(:lot_size)
      expect(ca.block).to be_a(Proc)
    end

    it "supports multiple computed attributes" do
      domain = Hecks.domain("RealEstate") do
        aggregate("Parcel") do
          attribute :area, Float
          attribute :density, Float
          computed(:lot_size) { area / 43560.0 }
          computed(:total) { area * density }
          command("CreateParcel") { attribute :area, Float }
        end
      end

      expect(domain.aggregates.first.computed_attributes.size).to eq(2)
    end
  end

  describe "Ruby code generation" do
    it "generates computed method on aggregate class" do
      domain = Hecks.domain("RealEstate") do
        aggregate("Parcel") do
          attribute :area, Float
          computed :lot_size do
            area / 43560.0
          end
          command("CreateParcel") { attribute :area, Float }
        end
      end

      gen = Hecks::Generators::Domain::AggregateGenerator.new(
        domain.aggregates.first, domain_module: "RealEstateDomain"
      )
      code = gen.generate

      expect(code).to include("def lot_size")
      expect(code).to include("area / 43560.0")
      expect(code).to include("# Computed attributes")
    end
  end

  describe "validation" do
    it "detects name collision between computed and regular attributes" do
      domain = Hecks.domain("RealEstate") do
        aggregate("Parcel") do
          attribute :area, Float
          computed(:area) { 42 }
          command("CreateParcel") { attribute :area, Float }
        end
      end

      validator = Hecks::Validator.new(domain)
      validator.valid?
      expect(validator.errors).to include(
        "Parcel: computed attribute 'area' collides with a regular attribute"
      )
    end
  end

  describe "defaults" do
    it "defaults computed_attributes to empty array" do
      domain = Hecks.domain("Simple") do
        aggregate("Thing") do
          attribute :name, String
          command("CreateThing") { attribute :name, String }
        end
      end

      expect(domain.aggregates.first.computed_attributes).to eq([])
    end
  end
end
