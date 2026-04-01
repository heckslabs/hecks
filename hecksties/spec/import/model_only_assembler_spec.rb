require "spec_helper"

RSpec.describe Hecks::Import::ModelOnlyAssembler do
  let(:model_data) do
    {
      "Pizza" => {
        associations: [
          { type: :belongs_to, name: "restaurant" },
          { type: :has_many, name: "toppings" },
          { type: :has_many, name: "orders", through: "order_items" },
          { type: :has_one, name: "nutrition_label" }
        ],
        validations: [
          { field: "name", rules: { presence: true } }
        ],
        enums: { "status" => %w[draft published archived] },
        state_machine: {
          field: "status", initial: "draft",
          transitions: [
            { event: "publish", from: "draft", to: "published" },
            { event: "archive", from: "published", to: "archived" }
          ]
        }
      },
      "Topping" => {
        associations: [{ type: :belongs_to, name: "pizza" }],
        validations: [],
        enums: {},
        state_machine: nil
      }
    }
  end

  subject(:dsl) { described_class.new(model_data, domain_name: "Pizzeria").assemble }

  it "generates valid DSL wrapper" do
    expect(dsl).to start_with('Hecks.domain "Pizzeria" do')
    expect(dsl).to end_with("end\n")
  end

  it "generates aggregates from model classes" do
    expect(dsl).to include('aggregate "Pizza" do')
    expect(dsl).to include('aggregate "Topping" do')
  end

  it "converts belongs_to to reference_to" do
    expect(dsl).to include('reference_to "Restaurant"')
  end

  it "converts has_many to list_of" do
    expect(dsl).to include('list_of "Topping"')
  end

  it "skips has_many through associations" do
    expect(dsl).not_to include("Order")
  end

  it "converts has_one to reference_to" do
    expect(dsl).to include('reference_to "NutritionLabel"')
  end

  it "includes enum attributes" do
    expect(dsl).to include('attribute :status, String, enum: ["draft", "published", "archived"]')
  end

  it "includes validations" do
    expect(dsl).to include('validation :name, {:presence=>true}')
  end

  it "generates lifecycle from state machine" do
    expect(dsl).to include('lifecycle :status, default: "draft" do')
    expect(dsl).to include('transition "PublishPizza" => "published"')
    expect(dsl).to include('transition "ArchivePizza" => "archived"')
  end

  context "with empty model data" do
    subject(:dsl) { described_class.new({}, domain_name: "Empty").assemble }

    it "generates a bare domain" do
      expect(dsl).to eq("Hecks.domain \"Empty\" do\nend\n")
    end
  end
end
