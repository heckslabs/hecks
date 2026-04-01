require "spec_helper"

RSpec.describe "deep_inspect" do
  subject(:workshop) { Hecks::Workshop.new("Pizzas") }

  before { allow($stdout).to receive(:puts) }

  describe "Navigator" do
    it "walks all elements of an aggregate" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        value_object "Topping" do
          attribute :name, String
        end
        command "CreatePizza" do
          attribute :name, String
        end
      end

      domain = workshop.to_domain
      navigator = Hecks::Workshop::Navigator.new(domain)

      labels = []
      navigator.walk("Pizza") { |_el, _depth, label| labels << label }

      expect(labels).to include("aggregate", "attribute", "value_object", "command", "param", "emits", "event")
    end

    it "returns nil for unknown aggregates" do
      domain = workshop.to_domain
      navigator = Hecks::Workshop::Navigator.new(domain)

      walked = false
      navigator.walk("Unknown") { walked = true }
      expect(walked).to be false
    end

    it "walks all aggregates" do
      workshop.aggregate("Pizza") { attribute :name, String }
      workshop.aggregate("Order") { attribute :quantity, Integer }

      domain = workshop.to_domain
      navigator = Hecks::Workshop::Navigator.new(domain)

      names = []
      navigator.walk_all do |el, _depth, label|
        names << el.name if label == "aggregate"
      end

      expect(names).to eq(["Pizza", "Order"])
    end
  end

  describe "Renderer" do
    it "renders attributes with type labels" do
      workshop.aggregate("Pizza") { attribute :name, String }
      domain = workshop.to_domain
      attr = domain.aggregates.first.attributes.first

      renderer = Hecks::Workshop::Renderer.new
      line = renderer.render(attr, depth: 1, label: "attribute")

      expect(line).to eq("  name: String")
    end

    it "renders commands with bracketed labels" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        command "CreatePizza" do
          attribute :name, String
        end
      end

      domain = workshop.to_domain
      cmd = domain.aggregates.first.commands.first

      renderer = Hecks::Workshop::Renderer.new
      line = renderer.render(cmd, depth: 1, label: "command")

      expect(line).to eq("  [command] CreatePizza")
    end
  end

  describe "Workshop#deep_inspect" do
    it "prints all aggregates with structure" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        value_object "Topping" do
          attribute :name, String
        end
        command "CreatePizza" do
          attribute :name, String
        end
      end

      expect { workshop.deep_inspect }.to output(
        /Pizzas Domain.*Pizza.*name: String.*\[value_object\] Topping.*\[command\] CreatePizza/m
      ).to_stdout
    end

    it "prints a single aggregate by name" do
      workshop.aggregate("Pizza") { attribute :name, String }
      workshop.aggregate("Order") { attribute :quantity, Integer }

      expect { workshop.deep_inspect("Pizza") }.to output(/Pizza.*name: String/m).to_stdout
      expect { workshop.deep_inspect("Pizza") }.not_to output(/Order/).to_stdout
    end

    it "reports unknown aggregate" do
      expect { workshop.deep_inspect("Unknown") }.to output(/Unknown aggregate/).to_stdout
    end

    it "includes policies" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        command "CreatePizza" do
          attribute :name, String
        end
        policy "AutoNotify" do
          on "CreatedPizza"
          trigger "NotifyChef"
        end
        command "NotifyChef" do
          attribute :name, String
        end
      end

      expect { workshop.deep_inspect("Pizza") }.to output(
        /\[policy\] AutoNotify: CreatedPizza -> NotifyChef/
      ).to_stdout
    end

    it "includes validations" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        command "CreatePizza" do
          attribute :name, String
        end
        validation :name, presence: true
      end

      expect { workshop.deep_inspect("Pizza") }.to output(
        /\[validation\] name: presence: true/
      ).to_stdout
    end

    it "includes queries and scopes" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        attribute :status, String
        command "CreatePizza" do
          attribute :name, String
        end
        query "ByStyle" do |style|
          { style: style }
        end
        scope :active, status: "active"
      end

      expect { workshop.deep_inspect("Pizza") }.to output(
        /\[query\] ByStyle.*\[scope\] active/m
      ).to_stdout
    end

    it "includes references" do
      workshop.aggregate "Pizza" do
        attribute :name, String
        command "CreatePizza" do
          attribute :name, String
        end
      end

      workshop.aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer
        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end
      end

      expect { workshop.deep_inspect("Order") }.to output(
        /\[reference\] -> Pizza/
      ).to_stdout
    end
  end
end
