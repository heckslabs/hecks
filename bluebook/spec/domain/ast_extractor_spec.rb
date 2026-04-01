require "spec_helper"

RSpec.describe Hecks::AstExtractor do
  describe ".extract" do
    it "extracts domain name" do
      result = described_class.extract('Hecks.domain "Pizzas" do; end')
      expect(result[:name]).to eq("Pizzas")
    end

    it "returns empty domain for non-domain source" do
      result = described_class.extract("puts 'hello'")
      expect(result[:name]).to be_nil
      expect(result[:aggregates]).to eq([])
    end

    it "extracts aggregate names" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Product" do
            attribute :name, String
          end
          aggregate "Order" do
            attribute :total, Float
          end
        end
      RUBY
      result = described_class.extract(source)
      names = result[:aggregates].map { |a| a[:name] }
      expect(names).to eq(["Product", "Order"])
    end

    it "extracts attributes with types" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Product" do
            attribute :name, String
            attribute :price, Float
            attribute :quantity, Integer
          end
        end
      RUBY
      result = described_class.extract(source)
      attrs = result[:aggregates].first[:attributes]
      expect(attrs).to contain_exactly(
        hash_including(name: :name, type: "String", list: false),
        hash_including(name: :price, type: "Float", list: false),
        hash_including(name: :quantity, type: "Integer", list: false)
      )
    end

    it "extracts list_of attributes" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Pizza" do
            attribute :toppings, list_of("Topping")
          end
        end
      RUBY
      result = described_class.extract(source)
      attr = result[:aggregates].first[:attributes].first
      expect(attr[:name]).to eq(:toppings)
      expect(attr[:type]).to eq("Topping")
      expect(attr[:list]).to be true
    end

    it "extracts attribute defaults" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Order" do
            attribute :status, String, default: "pending"
          end
        end
      RUBY
      result = described_class.extract(source)
      attr = result[:aggregates].first[:attributes].first
      expect(attr[:default]).to eq("pending")
    end

    it "extracts commands with attributes" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Product" do
            command "CreateProduct" do
              attribute :name, String
              attribute :price, Float
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      cmd = result[:aggregates].first[:commands].first
      expect(cmd[:name]).to eq("CreateProduct")
      expect(cmd[:attributes].length).to eq(2)
      expect(cmd[:attributes].first[:name]).to eq(:name)
    end

    it "extracts command references" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Order" do
            command "PlaceOrder" do
              reference_to "Product", validate: :exists
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      ref = result[:aggregates].first[:commands].first[:references].first
      expect(ref[:type]).to eq("Product")
      expect(ref[:validate]).to eq(:exists)
    end

    it "extracts value objects" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Pizza" do
            value_object "Topping" do
              attribute :name, String
              attribute :amount, Integer
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      vo = result[:aggregates].first[:value_objects].first
      expect(vo[:name]).to eq("Topping")
      expect(vo[:attributes].length).to eq(2)
    end

    it "extracts value object invariants" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Pizza" do
            value_object "Topping" do
              attribute :amount, Integer
              invariant "must be positive" do
                amount > 0
              end
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      inv = result[:aggregates].first[:value_objects].first[:invariants].first
      expect(inv[:message]).to eq("must be positive")
    end

    it "extracts entities" do
      source = <<~RUBY
        Hecks.domain "Banking" do
          aggregate "Account" do
            entity "LedgerEntry" do
              attribute :amount, Float
              attribute :description, String
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      ent = result[:aggregates].first[:entities].first
      expect(ent[:name]).to eq("LedgerEntry")
      expect(ent[:attributes].length).to eq(2)
    end

    it "extracts validations" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Product" do
            validation :name, presence: true
          end
        end
      RUBY
      result = described_class.extract(source)
      val = result[:aggregates].first[:validations].first
      expect(val[:field]).to eq(:name)
      expect(val[:rules]).to eq(presence: true)
    end

    it "extracts specifications" do
      source = <<~RUBY
        Hecks.domain "Banking" do
          aggregate "Loan" do
            specification "HighRisk" do |loan|
              loan.principal > 50_000
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      spec = result[:aggregates].first[:specifications].first
      expect(spec[:name]).to eq("HighRisk")
    end

    it "extracts aggregate-level references" do
      source = <<~RUBY
        Hecks.domain "Banking" do
          aggregate "Account" do
            reference_to "Customer"
          end
        end
      RUBY
      result = described_class.extract(source)
      ref = result[:aggregates].first[:references].first
      expect(ref[:type]).to eq("Customer")
      expect(ref[:domain]).to be_nil
    end

    it "extracts queries" do
      source = <<~RUBY
        Hecks.domain "Shop" do
          aggregate "Order" do
            query "Pending" do
              where(status: "pending")
            end
          end
        end
      RUBY
      result = described_class.extract(source)
      query = result[:aggregates].first[:queries].first
      expect(query[:name]).to eq("Pending")
    end

    it "extracts domain-level policies with attribute maps" do
      source = <<~RUBY
        Hecks.domain "Banking" do
          policy "DisburseFunds" do
            on "IssuedLoan"
            trigger "Deposit"
            map account_id: :account_id, principal: :amount
          end
        end
      RUBY
      result = described_class.extract(source)
      pol = result[:policies].first
      expect(pol[:name]).to eq("DisburseFunds")
      expect(pol[:event_name]).to eq("IssuedLoan")
      expect(pol[:trigger_command]).to eq("Deposit")
      expect(pol[:attribute_map]).to eq(account_id: :account_id, principal: :amount)
    end

    it "extracts world goals" do
      source = <<~RUBY
        Hecks.domain "GovAI" do
          world_goals :transparency, :consent, :privacy
        end
      RUBY
      result = described_class.extract(source)
      expect(result[:world_goals]).to eq([:transparency, :consent, :privacy])
    end

    it "extracts services" do
      source = <<~RUBY
        Hecks.domain "Banking" do
          service "TransferMoney" do
            attribute :source_id, String
            attribute :amount, Float
            coordinates "Account", "Ledger"
          end
        end
      RUBY
      result = described_class.extract(source)
      svc = result[:services].first
      expect(svc[:name]).to eq("TransferMoney")
      expect(svc[:attributes].length).to eq(2)
      expect(svc[:coordinates]).to eq(["Account", "Ledger"])
    end
  end

  describe ".extract_file" do
    let(:root) { File.expand_path("../../..", __dir__) }

    it "extracts from the pizzas example file" do
      path = File.join(root, "examples/pizzas/PizzasBluebook")
      result = described_class.extract_file(path)
      expect(result[:name]).to eq("Pizzas")
      expect(result[:aggregates].length).to eq(2)
      agg_names = result[:aggregates].map { |a| a[:name] }
      expect(agg_names).to contain_exactly("Pizza", "Order")
    end

    it "extracts from the banking example file" do
      path = File.join(root, "examples/banking/BankingBluebook")
      result = described_class.extract_file(path)
      expect(result[:name]).to eq("Banking")
      expect(result[:aggregates].length).to eq(4)
      expect(result[:policies].length).to eq(2)
    end
  end
end
