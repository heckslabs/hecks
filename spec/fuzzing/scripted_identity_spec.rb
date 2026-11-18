require "spec_helper"
require "hecks/fuzzing"

RSpec.describe Hecks::Fuzzing::ScriptedIdentity do
  let(:port) { Hecks::Ports::IdentityGeneration }
  let(:scripted) { Hecks::Runtime::Registry.new }
  let(:other) { Hecks::Runtime::Registry.new }

  def mint_twice(ids)
    port.standing_in(scripted, described_class.new(ids)) { [port.uuid(scripted), port.uuid(scripted)] }
  end

  it "answers the scripted ids in order through the identity port" do
    expect(mint_twice(%w[a b])).to eq(%w[a b])
  end

  it "refuses as an unbound port does once the script is spent" do
    expect { mint_twice(%w[a]) }.to raise_error(Hecks::Runtime::WiringError, /no id left/)
  end

  it "leaves every other registry to its adapter while the block runs" do
    port.standing_in(scripted, described_class.new(%w[a])) do
      expect { port.uuid(other) }.to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end
  end

  it "leaves the scripted registry to its adapter again after the block" do
    mint_twice(%w[a b])
    expect { port.uuid(scripted) }.to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
  end
end
