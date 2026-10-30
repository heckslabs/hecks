require "hecks"

RSpec.describe Hecks::Ports::AdapterRegistry do
  before { described_class.reset! }
  after { described_class.reset! }

  let(:adapter) { Class.new }

  it "finds an adapter by the capability it provides" do
    described_class.register("Sqlite", adapter, provides: ["persistence"])
    expect(described_class.lookup("persistence")).to eq([["Sqlite", adapter]])
  end

  it "returns nothing for a capability no adapter provides" do
    described_class.register("Sqlite", adapter, provides: ["persistence"])
    expect(described_class.lookup("lineage")).to eq([])
  end

  it "lists the adapters that provide one capability by name" do
    described_class.register("Postgres", adapter, provides: ["persistence"])
    described_class.register("Heki", adapter, provides: ["persistence", "saga_store"])
    expect(described_class.lookup("persistence").map(&:first)).to eq(%w[Heki Postgres])
  end

  it "replaces an earlier registration under the same name" do
    described_class.register("Heki", adapter, provides: ["persistence"])
    replacement = Class.new
    described_class.register("Heki", replacement, provides: ["persistence"])
    expect(described_class.lookup("persistence")).to eq([["Heki", replacement]])
  end

  it "refuses a capability outside the closed list" do
    expect { described_class.register("Sqlite", adapter, provides: ["persistance"]) }
      .to raise_error(Hecks::Runtime::WiringError, /unknown capabilities persistance/)
  end

  it "refuses an adapter that provides nothing" do
    expect { described_class.register("Sqlite", adapter, provides: []) }
      .to raise_error(Hecks::Runtime::WiringError, /provides no capability/)
  end

  it "records loading adapters through the loading port" do
    loader = Class.new
    Hecks::Ports::Loading.bootstrap_with(loader)
    expect(described_class.lookup("loading").map(&:last)).to include(loader)
  end
end
