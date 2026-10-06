require "spec_helper"

RSpec.describe "value-object identity declarations" do
  let(:builder) { Hecks::Bluebook::DSL::AggregateBuilder }

  # A box whose identity is a named two-field value object with a nested value object.
  let(:location_box) do
    build_aggregate("SafeDepositBox") do
      value_object "BranchCode" do
        attribute :value, String
      end

      value_object "BoxIdentity" do
        attribute :branch, BranchCode
        attribute :number, Integer
      end

      identified_by BoxIdentity, as: :location
    end
  end

  # A box whose entity declares its identity inline, beside the box's own named identity.
  let(:visited_box) do
    build_aggregate("SafeDepositBox") do
      identified_by BoxNumber

      value_object "BoxNumber" do
        attribute :value, String
      end

      entity "Visit" do
        identified_by do
          attribute :day, String
          attribute :sequence, Integer
        end
      end
    end
  end

  def build_aggregate(name, &block)
    scoped = Hecks::Bluebook::DSL::ConstShim::ScopedConstant
    Hecks::Bluebook::DSL::ConstShim.with(->(constant) { scoped.for(constant) }) do
      Hecks::Bluebook::DSL::AggregateBuilder.build(name, &block)
    end
  end

  # The name and type of every attribute of `aggregate`.
  def typed(aggregate) = aggregate.attributes.map { |field| [field.name, field.type] }

  def account_number_aggregate
    build_aggregate("Account") do
      value_object "AccountNumber" do
        attribute :value, String
      end

      identified_by AccountNumber, as: :number
    end
  end

  def inline_identity_box
    build_aggregate("SafeDepositBox") do
      identified_by(as: :location) do
        attribute :branch_code, String
        attribute :box_number, Integer
      end
    end
  end

  def compound_key_box
    build_aggregate("SafeDepositBox") do
      attribute :branch_code, String
      attribute :box_number, Integer
      identified_by :branch_code, :box_number
    end
  end

  def single_symbol_account
    build_aggregate("Account") do
      attribute :number, String
      identified_by :number
    end
  end

  def identity_chapter
    Hecks::Bluebook::DSL::BluebookBuilder.build("IdentityFixture") do
      vision "identity declarations read as domain value concepts"

      aggregate "TransferInstruction" do
        identified_by do
          attribute :scheme, String
          attribute :end_to_end_id, String
        end
      end
    end
  end

  def building_optional_identity
    build_aggregate("OptionalIdentity") do
      identified_by do
        attribute :region, String, optional: true
      end
    end
  end

  def building_list_identity
    build_aggregate("ListIdentity") do
      identified_by do
        attribute :regions, list_of(String)
      end
    end
  end

  def declaring_identity_twice
    build_aggregate("Account") do
      value_object("AccountNumber") { attribute :value, String }
      identified_by AccountNumber, as: :number
      identified_by AccountNumber, as: :other_number
    end
  end

  def minting_a_declared_field
    build_aggregate("Account") do
      value_object("AccountNumber") { attribute :value, String }
      attribute :number, AccountNumber
      identified_by AccountNumber, as: :number
    end
  end

  def account_with_positions
    build_aggregate("Account") do
      value_object("AccountNumber") { attribute :value, String }
      attribute :opened_on, String
      identified_by AccountNumber, as: :number
      attribute :status, String
    end
  end

  it "mints a named single-field value-object identity", :aggregate_failures do
    account = account_number_aggregate

    expect(typed(account)).to eq([[:number, "AccountNumber"]])
    expect(account.identity_paths).to eq(["number.value"])
  end

  it "flattens every member of a named multi-field value object in declaration order", :aggregate_failures do
    expect(typed(location_box)).to eq([[:location, "BoxIdentity"]])
    expect(location_box.identity_paths).to eq(["location.branch.value", "location.number"])
    expect(location_box.identified_by).to eq(:location)
    expect(Hecks::Runtime::Identity.of(location_box, { location: { branch: { value: "PHX" }, number: 42 } })).to eq("PHX:42")
  end

  it "builds a bespoke inline value object in the aggregate namespace", :aggregate_failures do
    box = inline_identity_box

    expect(typed(box)).to eq([[:location, "SafeDepositBoxIdentity"]])
    expect(box.value_objects.map(&:hecks_name)).to include("SafeDepositBoxIdentity")
    expect(box.identity_paths).to eq(["location.branch_code", "location.box_number"])
  end

  it "keeps two or more existing attributes as an explicit compound key", :aggregate_failures do
    box = compound_key_box

    expect(box.attributes.map(&:name)).to eq(%i[branch_code box_number])
    expect(box.identity_paths).to eq(%w[branch_code box_number])
    expect(Hecks::Runtime::Identity.of(box, { branch_code: "PHX", box_number: 42 })).to eq("PHX:42")
  end

  it "keeps the one-symbol form readable only during the staged corpus migration" do
    expect(single_symbol_account.identity_paths).to eq(["number"])
  end

  it "uses the same inline declaration for entities and installs its type on the aggregate", :aggregate_failures do
    visit = visited_box.entities.fetch(0)

    expect(typed(visit)).to eq([[:identity, "SafeDepositBoxVisitIdentity"]])
    expect(visit.identity_paths).to eq(["identity.day", "identity.sequence"])
    expect(visited_box.value_objects.map(&:hecks_name)).to include("SafeDepositBoxVisitIdentity")
  end

  it "round-trips the resolved identity paths and synthesized value objects through assembly" do
    chapter = identity_chapter

    expect(Hecks::Bluebook::Assembly.call(chapter.to_h).to_h).to eq(chapter.to_h)
  end

  it "refuses optional and list-valued identity members at declaration time", :aggregate_failures do
    expect { building_optional_identity }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /identity member identity.region is optional/)
    expect { building_list_identity }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /identity member identity.regions is a list/)
  end

  it "refuses duplicate identity declarations and duplicate minted fields", :aggregate_failures do
    expect { declaring_identity_twice }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /declares identified_by more than once/)
    expect { minting_a_declared_field }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /mints :number, but that attribute is already declared/)
  end

  it "preserves the declaration position of a minted identity field" do
    expect(account_with_positions.attributes.map(&:name)).to eq(%i[opened_on number status])
  end

  it "declares a minimum arity of two for the variadic compound-key grammar" do
    rows = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:arguments].select do |row|
      row[:keyword] == "identified_by" && row[:kind] == "symbol" && row[:named].empty?
    end

    expect(rows.map { |row| [row[:context], row[:variadic], row[:minimum]] }.sort)
      .to eq([["Aggregate", "true", "2"], ["Entity", "true", "2"]])
  end
end
