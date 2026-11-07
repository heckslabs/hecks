require "spec_helper"
require "hecks/fuzzing"

RSpec.describe Hecks::Fuzzing::ScriptedIdentity do
  def mint_twice(ids)
    Hecks::Ports::IdentityGeneration.standing_in(described_class.new(ids)) do
      [Hecks::Ports::IdentityGeneration.uuid(nil), Hecks::Ports::IdentityGeneration.uuid(nil)]
    end
  end

  it "answers the scripted ids in order through the identity port" do
    expect(mint_twice(%w[a b])).to eq(%w[a b])
  end

  it "refuses as an unbound port does once the script is spent" do
    expect { mint_twice(%w[a]) }.to raise_error(Hecks::Runtime::WiringError, /no id left/)
  end

  it "leaves the port to its adapter again after the block" do
    mint_twice(%w[a b])
    expect { Hecks::Ports::IdentityGeneration.uuid(Hecks::Runtime::Registry.new) }
      .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
  end
end
