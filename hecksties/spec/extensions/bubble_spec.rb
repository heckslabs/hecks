require "spec_helper"
require "hecks/extensions/bubble"

RSpec.describe HecksBubble do
  describe "Context DSL" do
    let(:context) do
      HecksBubble::Context.new do
        map_aggregate :Pizza do
          from_legacy :create,
            rename: { pizza_nm: :name, desc_text: :description },
            transform: { name: ->(v) { v.strip.capitalize } }

          map_out :create,
            rename: { name: :pizza_nm, description: :desc_text }
        end
      end
    end

    describe "#translate" do
      it "renames legacy fields to domain attributes" do
        result = context.translate(:Pizza, :create,
          pizza_nm: "margherita", desc_text: "Classic")

        expect(result[:name]).to eq("Margherita")
        expect(result[:description]).to eq("Classic")
      end

      it "applies value transforms after renaming" do
        result = context.translate(:Pizza, :create,
          pizza_nm: "  pepperoni  ", desc_text: "Spicy")

        expect(result[:name]).to eq("Pepperoni")
      end

      it "passes through unmapped fields" do
        result = context.translate(:Pizza, :create,
          pizza_nm: "test", extra: "bonus")

        expect(result[:extra]).to eq("bonus")
      end

      it "returns data unchanged for unmapped aggregates" do
        result = context.translate(:Order, :create, qty: 5)
        expect(result).to eq(qty: 5)
      end

      it "returns data unchanged for unmapped actions" do
        result = context.translate(:Pizza, :delete, id: "abc")
        expect(result).to eq(id: "abc")
      end
    end

    describe "#reverse" do
      it "maps domain attributes back to legacy field names" do
        result = context.reverse(:Pizza, :create,
          name: "Margherita", description: "Classic")

        expect(result[:pizza_nm]).to eq("Margherita")
        expect(result[:desc_text]).to eq("Classic")
      end

      it "passes through unmapped fields on reverse" do
        result = context.reverse(:Pizza, :create,
          name: "Test", id: "abc-123")

        expect(result[:pizza_nm]).to eq("Test")
        expect(result[:id]).to eq("abc-123")
      end

      it "returns data unchanged for unmapped aggregates" do
        result = context.reverse(:Order, :create, total: 42)
        expect(result).to eq(total: 42)
      end
    end

    describe "#mapped_aggregates" do
      it "lists aggregates with mappings" do
        expect(context.mapped_aggregates).to eq([:Pizza])
      end
    end

    describe "#mapper_for" do
      it "returns the mapper for a known aggregate" do
        expect(context.mapper_for(:Pizza)).to be_a(HecksBubble::AggregateMapper)
      end

      it "returns nil for unknown aggregates" do
        expect(context.mapper_for(:Order)).to be_nil
      end
    end
  end

  describe "multiple aggregates" do
    let(:context) do
      HecksBubble::Context.new do
        map_aggregate :Pizza do
          from_legacy :create, rename: { nm: :name }
        end

        map_aggregate :Order do
          from_legacy :place, rename: { qty: :quantity }
        end
      end
    end

    it "translates each aggregate independently" do
      pizza = context.translate(:Pizza, :create, nm: "Hawaiian")
      order = context.translate(:Order, :place, qty: 3)

      expect(pizza).to eq(name: "Hawaiian")
      expect(order).to eq(quantity: 3)
    end
  end

  describe "extension registration" do
    let(:domain) do
      Hecks.domain "BubbleTest" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end
    end

    it "adds bubble_context DSL to domain module" do
      app = Hecks.load(domain)
      Hecks.extension_registry[:bubble]&.call(
        Object.const_get("BubbleTestDomain"), domain, app
      )

      BubbleTestDomain.bubble_context do
        map_aggregate :Pizza do
          from_legacy :create, rename: { nm: :name }
        end
      end

      result = BubbleTestDomain.bubble.translate(:Pizza, :create, nm: "Test")
      expect(result).to eq(name: "Test")
    end
  end
end
