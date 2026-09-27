require "spec_helper"

RSpec.describe "relationship graph validation" do
  it "treats relationship declarations as aggregate-boundary edges" do
    expect do
      Hecks::Bluebook::DSL::BluebookBuilder.build("RelationshipCycle") do
        vision "a relationship ring is not an aggregate boundary"

        aggregate "Owner" do
          identified_by do
            attribute :number, String
          end

          has_many Teams
        end

        aggregate "Team" do
          identified_by do
            attribute :number, String
          end

          belongs_to Owner
        end
      end
    end.to raise_error(
      Hecks::Bluebook::DSL::Malformed,
      /reference cycle: (Owner -> Team -> Owner|Team -> Owner -> Team)/
    )
  end

  # Pins the DFS: every other cycle spec is a two-node ring, which a direct-pair
  # check would also catch. This ring needs a third aggregate in the middle (ADR 0025).
  # rubocop:disable-next RSpec/ExampleLength
  it "refuses a reference ring three aggregates long, not just a direct pair" do
    expect do
      Hecks::Bluebook::DSL::BluebookBuilder.build("RelationshipRing3") do
        vision "a three-aggregate ring is still a ring"

        aggregate "Alpha" do
          identified_by do
            attribute :number, String
          end

          reference_to Beta
        end

        aggregate "Beta" do
          identified_by do
            attribute :number, String
          end

          reference_to Gamma
        end

        aggregate "Gamma" do
          identified_by do
            attribute :number, String
          end

          reference_to Alpha
        end
      end
    end.to raise_error(
      Hecks::Bluebook::DSL::Malformed,
      /reference cycle: (Alpha -> Beta -> Gamma -> Alpha|Beta -> Gamma -> Alpha -> Beta|Gamma -> Alpha -> Beta -> Gamma)/
    )
  end

  it "still allows a self-reference — a hierarchy pointing at its own kind is not a ring" do
    expect do
      Hecks::Bluebook::DSL::BluebookBuilder.build("SelfReferenceOk") do
        vision "a self-reference is a hierarchy, not a ring"

        aggregate "Category" do
          identified_by do
            attribute :number, String
          end

          reference_to Category, as: :parent
        end
      end
    end.not_to raise_error
  end
end
