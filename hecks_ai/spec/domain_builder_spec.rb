require "spec_helper"

RSpec.describe Hecks::AI::DomainBuilder do
  def build(json)
    described_class.new(json).build
  end

  describe "#build" do
    context "with a minimal domain" do
      let(:domain_json) do
        {
          domain_name: "Library",
          aggregates: [
            {
              name: "Book",
              attributes: [
                { name: "title",  type: "String" },
                { name: "pages",  type: "Integer" }
              ],
              validations: [{ field: "title", presence: true }],
              commands: [
                { name: "AddBook",
                  attributes: [
                    { name: "title", type: "String" },
                    { name: "pages", type: "Integer" }
                  ]
                }
              ]
            }
          ]
        }
      end

      it "returns a valid Workshop" do
        workshop = build(domain_json)
        expect(workshop).to be_a(Hecks::Workshop)
        expect(workshop.aggregates).to include("Book")
      end

      it "builds the domain with the correct name" do
        workshop = build(domain_json)
        expect(workshop.to_domain.name).to eq("Library")
      end
    end

    context "with references" do
      let(:domain_json) do
        {
          domain_name: "Shop",
          aggregates: [
            {
              name: "Product",
              attributes: [{ name: "name", type: "String" }],
              commands: [{ name: "CreateProduct", attributes: [{ name: "name", type: "String" }] }]
            },
            {
              name: "Order",
              attributes: [{ name: "quantity", type: "Integer" }],
              references: [{ target: "Product" }],
              commands: [
                { name: "PlaceOrder",
                  attributes: [
                    { name: "product_id", type: "reference_to(Product)" },
                    { name: "quantity",   type: "Integer" }
                  ]
                }
              ]
            }
          ]
        }
      end

      it "includes both aggregates" do
        workshop = build(domain_json)
        expect(workshop.aggregates).to include("Product", "Order")
      end
    end

    context "with value objects and entities" do
      let(:domain_json) do
        {
          domain_name: "Catalog",
          aggregates: [
            {
              name: "Item",
              attributes: [{ name: "name", type: "String" }],
              value_objects: [
                { name: "Dimension",
                  attributes: [
                    { name: "width",  type: "Float" },
                    { name: "height", type: "Float" }
                  ]
                }
              ],
              entities: [
                { name: "Variant",
                  attributes: [{ name: "sku", type: "String" }]
                }
              ],
              commands: [{ name: "CreateItem", attributes: [{ name: "name", type: "String" }] }]
            }
          ]
        }
      end

      it "builds without errors" do
        expect { build(domain_json) }.not_to raise_error
      end
    end

    context "when domain_name is missing" do
      it "raises a descriptive error" do
        expect { build({ aggregates: [] }) }
          .to raise_error(RuntimeError, /domain_name is required/)
      end
    end

    context "with lifecycle" do
      let(:domain_json) do
        {
          domain_name: "Tasks",
          aggregates: [
            {
              name: "Task",
              attributes: [
                { name: "title",  type: "String" },
                { name: "status", type: "String" }
              ],
              commands: [
                { name: "CreateTask", attributes: [{ name: "title", type: "String" }] },
                { name: "CompleteTask", attributes: [{ name: "task_id", type: "reference_to(Task)" }] }
              ],
              lifecycle: {
                field: "status",
                default: "open",
                transitions: [{ command: "CompleteTask", target: "done" }]
              }
            }
          ]
        }
      end

      it "builds without errors" do
        expect { build(domain_json) }.not_to raise_error
      end
    end
  end
end
