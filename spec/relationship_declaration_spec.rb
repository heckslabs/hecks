require "spec_helper"

RSpec.describe "relationship declarations" do
  def build_chapter(&block)
    Hecks::Bluebook::DSL::BluebookBuilder.build("RelationshipFixture", &block)
  end

  it "preserves relationship kind and cardinality through canonical IR and assembly" do
    chapter = build_chapter do
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

    portfolio = chapter.aggregate("Portfolio")
    expect(
      portfolio.attributes.last(4).map do |field|
        [field.name, field.type.to_s, field.list?, field.optional?, field.relationship]
      end
    ).to eq(
      [
        [:customer, "Reference<Customer>", false, false, "belongs_to"],
        [:profile, "Reference<Profile>", false, true, "has_one"],
        [:accounts, "Reference<Account>", true, false, "has_many"],
        [:settlement_customer, "Reference<Customer>", false, false, "reference_to"]
      ]
    )

    expect(Hecks::Bluebook::Assembly.call(chapter.to_h).to_h).to eq(chapter.to_h)
  end

  it "uses the same relationship declarations on an entity" do
    chapter = build_chapter do
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

    review = chapter.aggregate("Case").entities.fetch(0)
    expect(review.attributes.last(3).map { |field| [field.name, field.list?, field.relationship] })
      .to eq([[:customer, false, "belongs_to"], [:related_accounts, true, "has_many"],
              [:reviewer, false, "reference_to"]])
  end

  it "uses an empty list for no has_many members and refuses optional cardinality" do
    chapter = build_chapter do
      vision "an empty relationship collection already means none"

      aggregate("Account") { identified_by { attribute :number, String } }

      aggregate "Portfolio" do
        identified_by { attribute :number, String }
        has_many Accounts
      end
    end

    portfolio = chapter.aggregate("Portfolio")
    instance = Hecks::Runtime::Instance.new(aggregate: portfolio, id: "p-1")
    expect(instance[:accounts]).to eq([])

    expect do
      build_chapter do
        vision "optional is not collection cardinality"
        aggregate("Account") { identified_by { attribute :number, String } }
        aggregate("Portfolio") do
          identified_by { attribute :number, String }
          has_many Accounts, optional: true
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /has_many takes no optional/)
  end
end
