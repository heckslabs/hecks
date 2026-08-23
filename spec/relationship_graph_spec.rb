require "spec_helper"

RSpec.describe "relationship graph validation" do
  it "treats relationship declarations as aggregate-boundary edges" do
    expect do
      Hecksagain::Bluebook::DSL::BluebookBuilder.build("RelationshipCycle") do
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
      Hecksagain::Bluebook::DSL::Malformed,
      /reference cycle: (Owner -> Team -> Owner|Team -> Owner -> Team)/
    )
  end
end
