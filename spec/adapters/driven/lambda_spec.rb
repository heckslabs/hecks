require "hecks"
require "hecks/adapters/driven/lambda"

# `Lambda#initialize`'s own settings parsing — `Client.new` is stubbed so
# these specs never require live AWS credentials or a real function to
# invoke; each proves the fixed `key?`-gated settings read, not the AWS
# transport.
RSpec.describe Hecks::Adapters::Lambda do
  let(:aggregate) { boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  # `settings[:region] || settings["region"] || "us-east-1"` used to coerce
  # a genuinely stored `false` at :region into the "us-east-1" fallback —
  # indistinguishable from :region being absent entirely.
  it "reads a `false`-valued :region setting back as itself, not the \"us-east-1\" fallback" do
    # rubocop:disable-next RSpec/StubbedMock -- the args passed to Client.new
    # are the assertion (the false/absent :region distinction); `allow`
    # wouldn't fail if the fix regressed and .new were never called this way.
    expect(described_class::Client).to receive(:new)
      .with(domain: anything, region: false, function: nil)
      .and_return(instance_double(described_class::Client))

    described_class.new(aggregate: aggregate, settings: { region: false })
  end

  it "still falls back to \"us-east-1\" when :region is genuinely absent" do
    # rubocop:disable-next RSpec/StubbedMock -- the args passed to Client.new
    # are the assertion (the false/absent :region distinction); `allow`
    # wouldn't fail if the fix regressed and .new were never called this way.
    expect(described_class::Client).to receive(:new)
      .with(domain: anything, region: "us-east-1", function: nil)
      .and_return(instance_double(described_class::Client))

    described_class.new(aggregate: aggregate, settings: {})
  end

  # A deployment whose function isn't `hecks-<domain>` — a `.world`'s own
  # `stack_prefix`/`stack_name` can name a stack that predates a rename,
  # and nothing downstream of that could previously be told about it.
  # Found live: embryonautfoundersapp deploys as `hecksagain-embryonaut`,
  # so every Ruby-side read and dispatch for it had been invoking a
  # function that does not exist.
  it "passes a :function setting straight through to the client" do
    # rubocop:disable-next RSpec/StubbedMock -- the args passed to Client.new
    # are the assertion.
    expect(described_class::Client).to receive(:new)
      .with(domain: anything, region: anything, function: "hecksagain-embryonaut")
      .and_return(instance_double(described_class::Client))

    described_class.new(aggregate: aggregate, settings: { function: "hecksagain-embryonaut" })
  end

  it "reads the same setting string-keyed, the way a round-tripped export spells it" do
    # rubocop:disable-next RSpec/StubbedMock -- the args passed to Client.new
    # are the assertion.
    expect(described_class::Client).to receive(:new)
      .with(domain: anything, region: anything, function: "hecksagain-embryonaut")
      .and_return(instance_double(described_class::Client))

    described_class.new(aggregate: aggregate, settings: { "function" => "hecksagain-embryonaut" })
  end

  it "still falls back to the aggregate's own name in @prefix when :domain is genuinely absent" do
    allow(described_class::Client).to receive(:new).and_return(instance_double(described_class::Client))

    adapter = described_class.new(aggregate: aggregate, settings: {})

    expect(adapter.instance_variable_get(:@prefix)).to eq("#{aggregate.name}::#{aggregate.hecks_name}#")
  end
end
