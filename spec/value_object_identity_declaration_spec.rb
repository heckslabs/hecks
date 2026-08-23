require "spec_helper"

RSpec.describe "value-object identity declarations" do
  let(:builder) { Hecksagain::Bluebook::DSL::AggregateBuilder }

  def build_aggregate(name, &block)
    scoped = Hecksagain::Bluebook::DSL::ConstShim::ScopedConstant
    Hecksagain::Bluebook::DSL::ConstShim.with(->(constant) { scoped.for(constant) }) do
      Hecksagain::Bluebook::DSL::AggregateBuilder.build(name, &block)
    end
  end

  it "mints a named single-field value-object identity" do
    account = build_aggregate("Account") do
      value_object "AccountNumber" do
        attribute :value, String
      end

      identified_by AccountNumber, as: :number
    end

    expect(account.attributes.map { |field| [field.name, field.type] })
      .to eq([[:number, "AccountNumber"]])
    expect(account.identity_paths).to eq(["number.value"])
  end

  it "flattens every member of a named multi-field value object in declaration order" do
    box = build_aggregate("SafeDepositBox") do
      value_object "BranchCode" do
        attribute :value, String
      end

      value_object "BoxIdentity" do
        attribute :branch, BranchCode
        attribute :number, Integer
      end

      identified_by BoxIdentity, as: :location
    end

    expect(box.attributes.map { |field| [field.name, field.type] })
      .to eq([[:location, "BoxIdentity"]])
    expect(box.identity_paths).to eq(["location.branch.value", "location.number"])
    expect(box.identified_by).to eq(:location)
    expect(
      Hecksagain::Runtime::Identity.of(
        box,
        { location: { branch: { value: "PHX" }, number: 42 } }
      )
    ).to eq("PHX:42")
  end

  it "builds a bespoke inline value object in the aggregate namespace" do
    box = build_aggregate("SafeDepositBox") do
      identified_by(as: :location) do
        attribute :branch_code, String
        attribute :box_number, Integer
      end
    end

    expect(box.attributes.map { |field| [field.name, field.type] })
      .to eq([[:location, "SafeDepositBoxIdentity"]])
    expect(box.value_objects.map(&:hecks_name)).to include("SafeDepositBoxIdentity")
    expect(box.identity_paths).to eq(["location.branch_code", "location.box_number"])
  end

  it "keeps two or more existing attributes as an explicit compound key" do
    box = build_aggregate("SafeDepositBox") do
      attribute :branch_code, String
      attribute :box_number, Integer
      identified_by :branch_code, :box_number
    end

    expect(box.attributes.map(&:name)).to eq(%i[branch_code box_number])
    expect(box.identity_paths).to eq(%w[branch_code box_number])
    expect(Hecksagain::Runtime::Identity.of(box, { branch_code: "PHX", box_number: 42 }))
      .to eq("PHX:42")
  end

  it "keeps the one-symbol form readable only during the staged corpus migration" do
    account = build_aggregate("Account") do
      attribute :number, String
      identified_by :number
    end

    expect(account.identity_paths).to eq(["number"])
  end

  it "uses the same inline declaration for entities and installs its type on the aggregate" do
    box = build_aggregate("SafeDepositBox") do
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

    visit = box.entities.fetch(0)
    expect(visit.attributes.map { |field| [field.name, field.type] })
      .to eq([[:identity, "SafeDepositBoxVisitIdentity"]])
    expect(visit.identity_paths).to eq(["identity.day", "identity.sequence"])
    expect(box.value_objects.map(&:hecks_name)).to include("SafeDepositBoxVisitIdentity")
  end

  it "round-trips the resolved identity paths and synthesized value objects through assembly" do
    chapter = Hecksagain::Bluebook::DSL::BluebookBuilder.build("IdentityFixture") do
      vision "identity declarations read as domain value concepts"

      aggregate "TransferInstruction" do
        identified_by do
          attribute :scheme, String
          attribute :end_to_end_id, String
        end
      end
    end

    expect(Hecksagain::Bluebook::Assembly.call(chapter.to_h).to_h).to eq(chapter.to_h)
  end

  it "refuses optional and list-valued identity members at declaration time" do
    expect do
      build_aggregate("OptionalIdentity") do
        identified_by do
          attribute :region, String, optional: true
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /identity member identity.region is optional/)

    expect do
      build_aggregate("ListIdentity") do
        identified_by do
          attribute :regions, list_of(String)
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /identity member identity.regions is a list/)
  end

  it "refuses duplicate identity declarations and duplicate minted fields" do
    expect do
      build_aggregate("Account") do
        value_object("AccountNumber") { attribute :value, String }
        identified_by AccountNumber, as: :number
        identified_by AccountNumber, as: :other_number
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares identified_by more than once/)

    expect do
      build_aggregate("Account") do
        value_object("AccountNumber") { attribute :value, String }
        attribute :number, AccountNumber
        identified_by AccountNumber, as: :number
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /mints :number, but that attribute is already declared/)
  end

  it "preserves the declaration position of a minted identity field" do
    account = build_aggregate("Account") do
      value_object("AccountNumber") { attribute :value, String }
      attribute :opened_on, String
      identified_by AccountNumber, as: :number
      attribute :status, String
    end

    expect(account.attributes.map(&:name)).to eq(%i[opened_on number status])
  end

  it "declares a minimum arity of two for the variadic compound-key grammar" do
    rows = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call[:arguments].select do |row|
      row[:keyword] == "identified_by" && row[:kind] == "symbol" && row[:named].empty?
    end

    expect(rows.map { |row| [row[:context], row[:variadic], row[:minimum]] }.sort)
      .to eq([["Aggregate", "true", "2"], ["Entity", "true", "2"]])
  end
end
