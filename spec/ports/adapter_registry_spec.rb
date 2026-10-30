require "hecks"

RSpec.describe Hecks::Ports::AdapterRegistry do
  # Other specs in this process rely on the core adapters the boot registered, so put back
  # whatever was there rather than leaving the registry empty.
  around do |example|
    saved = described_class.all
    described_class.reset!
    example.run
    described_class.reset!
    saved.each { |name, entry| described_class.register(name, entry[:klass], provides: entry[:provides]) }
  end

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

  it "fetches an adapter class by its name" do
    described_class.register("Sqlite", adapter, provides: ["persistence"])
    expect(described_class.fetch("Sqlite")).to eq(adapter)
  end

  it "refuses an adapter that lacks the capability its port needs" do
    described_class.register("Probe", adapter, provides: ["lineage"])
    expect { described_class.check_capability!("Probe", "persistence") }
      .to raise_error(Hecks::Runtime::WiringError, /needs the persistence capability/)
  end

  it "passes an adapter that provides the capability" do
    described_class.register("Probe", adapter, provides: ["persistence"])
    expect { described_class.check_capability!("Probe", "persistence") }.not_to raise_error
  end

  it "maps every port it checks to a capability in the closed list" do
    mapped = Hecks::Ports::AdapterRegistry::PORT_CAPABILITIES.values
    expect(mapped - Hecks::Ports::AdapterRegistry::CAPABILITIES).to be_empty
  end

  it "fetches nothing for a name no adapter registered" do
    expect(described_class.fetch("Nope")).to be_nil
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
