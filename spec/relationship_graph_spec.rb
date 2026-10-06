require "spec_helper"

RSpec.describe "relationship graph validation" do
  OWNER_TEAM_RING = proc do
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

  # Pins the DFS: every other cycle spec is a two-node ring, which a direct-pair
  # check would also catch. This ring needs a third aggregate in the middle (ADR 0025).
  THREE_AGGREGATE_RING = proc do
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

  SELF_REFERENCE = proc do
    vision "a self-reference is a hierarchy, not a ring"

    aggregate "Category" do
      identified_by do
        attribute :number, String
      end

      reference_to Category, as: :parent
    end
  end

  def build_chapter(name, &block) = Hecks::Bluebook::DSL::BluebookBuilder.build(name, &block)

  it "treats relationship declarations as aggregate-boundary edges" do
    expect { build_chapter("RelationshipCycle", &OWNER_TEAM_RING) }.to raise_error(
      Hecks::Bluebook::DSL::Malformed,
      /reference cycle: (Owner -> Team -> Owner|Team -> Owner -> Team)/
    )
  end

  it "refuses a reference ring three aggregates long, not just a direct pair" do
    expect { build_chapter("RelationshipRing3", &THREE_AGGREGATE_RING) }.to raise_error(
      Hecks::Bluebook::DSL::Malformed,
      /reference cycle: (Alpha -> Beta -> Gamma -> Alpha|Beta -> Gamma -> Alpha -> Beta|Gamma -> Alpha -> Beta -> Gamma)/
    )
  end

  it "still allows a self-reference — a hierarchy pointing at its own kind is not a ring" do
    expect { build_chapter("SelfReferenceOk", &SELF_REFERENCE) }.not_to raise_error
  end
end
