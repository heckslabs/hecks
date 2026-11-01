require "hecks"
require_relative "../../support/postgres_probe"

# A domain whose PostgresEra binding is not committed (the Hecks domain: its persistence lives in
# gitignored local files) still names its mint command in the committed world, at the top level:
# `minting commands: ["Era.MintHeld"]`. The binding's settings carry it with any list the
# persistence block gives, so the adapter reads one answer.
RSpec.describe "mints_era in the world" do
  def registry_with(&world_block)
    Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.expand_path("../../../lib/hecks/adapters/driven/postgres_era.adapter", __dir__))
        Hecks.world("Ledger", &world_block)
      end
    end
  end

  def names(registry)
    Hecks::Ports::Persistence::MintDoor.names(registry.binding_settings("Ledger", "persisted_by", "PostgresEra"))
  end

  let(:both) do
    proc do
      minting commands: ["Era.MintHeld"]
      persisted_by("PostgresEra") do
        database "postgres://x@localhost/ledger"
        mints_era "Maintenance.MintEra"
      end
    end
  end

  it "reaches a PostgresEra binding the world's persistence block does not mention" do
    expect(names(registry_with { minting commands: ["Era.MintHeld"] })).to eq(["Era.MintHeld"])
  end

  it "joins the names the persistence block gives" do
    expect(names(registry_with(&both))).to contain_exactly("Era.MintHeld", "Maintenance.MintEra")
  end

  it "adds nothing when the world names no command" do
    expect(names(registry_with { realm "Ledger" })).to eq([])
  end
end
