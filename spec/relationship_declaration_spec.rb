require "spec_helper"

RSpec.describe "relationship declarations" do
  # One aggregate declares all four relationship kinds so IR and assembly are checked together.
  PORTFOLIO_CHAPTER = proc do
    vision "relationships read as the domain concepts they represent"

    aggregate "Customer" do
      identified_by do
        attribute :number, String
      end
    end

    aggregate "Profile" do
      identified_by do
        attribute :handle, String
      end
    end

    aggregate "Account" do
      identified_by do
        attribute :number, String
      end
    end

    aggregate "Portfolio" do
      identified_by do
        attribute :number, String
      end

      belongs_to Customer
      has_one Profile, optional: true
      has_many Accounts
      reference_to Customer, as: :settlement_customer
    end
  end

  # [name, type, list?, optional?, relationship] of the four relationship fields on Portfolio.
  PORTFOLIO_RELATIONSHIPS = [
    [:customer, "Reference<Customer>", false, false, "belongs_to"],
    [:profile, "Reference<Profile>", false, true, "has_one"],
    [:accounts, "Reference<Account>", true, false, "has_many"],
    [:settlement_customer, "Reference<Customer>", false, false, "reference_to"]
  ].freeze

  # Same declarations on an owned entity rather than an aggregate.
  CASE_CHAPTER = proc do
    vision "owned pieces may retain structural relationships"

    aggregate "Customer" do
      identified_by do
        attribute :number, String
      end
    end

    aggregate "Account" do
      identified_by do
        attribute :number, String
      end
    end

    aggregate "Case" do
      identified_by do
        attribute :number, String
      end

      entity "Review" do
        identified_by do
          attribute :sequence, Integer
        end

        belongs_to Customer
        has_many Accounts, as: :related_accounts
        reference_to Customer, as: :reviewer
      end
    end
  end

  EMPTY_HAS_MANY_CHAPTER = proc do
    vision "an empty relationship collection already means none"

    aggregate("Account") { identified_by { attribute :number, String } }

    aggregate "Portfolio" do
      identified_by { attribute :number, String }
      has_many Accounts
    end
  end

  OPTIONAL_HAS_MANY_CHAPTER = proc do
    vision "optional is not collection cardinality"
    aggregate("Account") { identified_by { attribute :number, String } }
    aggregate("Portfolio") do
      identified_by { attribute :number, String }
      has_many Accounts, optional: true
    end
  end

  # `Naming.singularize` must undo the "-es" suffix `plural` mints, or
  # `has_many Boxes` resolves to a phantom "Boxe" instead of Box.
  BOXES_CHAPTER = proc do
    vision "a plural ending in -es still resolves to its real singular"

    aggregate("Box") { identified_by { attribute :number, String } }

    aggregate "Shelf" do
      identified_by { attribute :number, String }
      has_many Boxes
    end
  end

  def build_chapter(&block)
    Hecks::Bluebook::DSL::BluebookBuilder.build("RelationshipFixture", &block)
  end

  def relationship_rows(fields)
    fields.map { |field| [field.name, field.type.to_s, field.list?, field.optional?, field.relationship] }
  end

  it "preserves relationship kind and cardinality through canonical IR and assembly", :aggregate_failures do
    chapter = build_chapter(&PORTFOLIO_CHAPTER)
    fields = chapter.aggregate("Portfolio").attributes.last(4)

    expect(relationship_rows(fields)).to eq(PORTFOLIO_RELATIONSHIPS)
    expect(Hecks::Bluebook::Assembly.call(chapter.to_h).to_h).to eq(chapter.to_h)
  end

  it "uses the same relationship declarations on an entity" do
    review = build_chapter(&CASE_CHAPTER).aggregate("Case").entities.fetch(0)

    expect(review.attributes.last(3).map { |field| [field.name, field.list?, field.relationship] })
      .to eq([[:customer, false, "belongs_to"], [:related_accounts, true, "has_many"], [:reviewer, false, "reference_to"]])
  end

  it "uses an empty list for no has_many members" do
    portfolio = build_chapter(&EMPTY_HAS_MANY_CHAPTER).aggregate("Portfolio")

    expect(Hecks::Runtime::Instance.new(aggregate: portfolio, id: "p-1")[:accounts]).to eq([])
  end

  it "refuses optional cardinality on has_many" do
    expect { build_chapter(&OPTIONAL_HAS_MANY_CHAPTER) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /has_many takes no optional/)
  end

  it "resolves has_many against a real aggregate whose plural adds -es", :aggregate_failures do
    shelf = build_chapter(&BOXES_CHAPTER).aggregate("Shelf")

    expect(shelf.attributes.last.type.to_s).to eq("Reference<Box>")
    expect(shelf.reference_targets).to include("Box")
  end
end
