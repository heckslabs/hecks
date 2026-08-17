require "spec_helper"

RSpec.describe Hecksagain::Ports::Query do
  let(:specification) do
    Hecksagain::Bluebook::Query.new(name: "Accounts")
  end

  it "uses an adapter's single native query hook" do
    adapter = Class.new do
      def query(specification, args, context:)
        [specification.name, args, context[:domain]]
      end
    end.new
    repository = Struct.new(:adapter).new(adapter)

    expect(described_class.execute(repository, specification, { limit: 5 }, context: { domain: "Banking" }))
      .to eq(["Accounts", { limit: 5 }, "Banking"])
  end

  it "returns nil so the shared interpreter can handle adapters without native queries" do
    expect(described_class.execute(Object.new, specification)).to be_nil
  end

  it "rejects contradictory pagination before an adapter is called" do
    specification = Hecksagain::Bluebook::Query.new(
      name:   "Accounts",
      offset: Hecksagain::QuerySpecification::Common::OffsetSpec.new(value: 5),
      cursor: Hecksagain::QuerySpecification::Common::CursorSpec.new(value: "next")
    )
    adapter = Struct.new(:called) do
      def query(*) = self.called = true
    end.new(false)

    expect { described_class.execute(adapter, specification) }
      .to raise_error(described_class::Unsupported, /cursor and offset/)
    expect(adapter.called).to be(false)
  end
end
