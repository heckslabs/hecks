require "spec_helper"
require "hecks/fuzzing"
require_relative "../fixtures/sequential_identity"

RSpec.describe Hecks::Fuzzing::ScriptedIdentity do
  let(:port) { Hecks::Ports::IdentityGeneration }
  let(:registry) { bound_registry }
  let(:others) { ->(port_name, _asked) { "#{port_name} stand-in" } }

  def bound_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(File.expand_path("../../lib/hecks/ports/identity_generation.port", __dir__))
      Kernel.load(File.expand_path("../fixtures/sequential_identity.adapter", __dir__))
    end
    registry
  end

  def scripted(ids, &)
    Hecks::Runtime::AdapterLookup.standing_in(described_class.over(ids, others), &)
  end

  def mint_twice(ids) = scripted(ids) { [port.uuid(registry), port.uuid(registry)] }

  it "answers the scripted ids in order through the identity port" do
    expect(mint_twice(%w[a b])).to eq(%w[a b])
  end

  it "refuses as an unbound port does once the script is spent" do
    expect { mint_twice(%w[a]) }.to raise_error(Hecks::Runtime::WiringError, /no id left/)
  end

  it "asks the stand-in it was built over for every other port" do
    expect(scripted(%w[a]) { Hecks::Runtime::AdapterLookup.stand_in_for("clock", "the time") }).to eq("clock stand-in")
  end

  it "leaves the identity port to its bound adapter when no stand-in is in place" do
    Hecks::Adapters::SequentialIdentity.reset!
    mint_twice(%w[a b])
    expect(port.uuid(registry)).to eq("1")
  end
end
