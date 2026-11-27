require "hecks"

# The Hecks domain keeps its renamed aggregate in the table they were written to, and names its
# mint command, in the world that is committed. A development checkout keeps its persistence in
# local files, so these two facts cannot live there.
RSpec.describe "the Hecks domain's committed world names" do
  let(:registry) do
    Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__)).registry.tap(&:apply_world_names!)
  end
  let(:hecks) { registry.bluebook("Hecks") }

  it "stores the renamed Workspace under the table its earlier name wrote" do
    expect(hecks.aggregate("Workspace").storage_name).to eq("checkout")
  end

  it "keeps formerly_known_as out of the Hecks bluebooks" do
    expect(hecks.aggregates.map(&:former_name).compact).to be_empty
  end

  it "names SchemaRevision.MintHeld as the command an unminted boot may write" do
    settings = registry.binding_settings("Hecks", "persisted_by", "PostgresEra")
    expect(Hecks::Ports::Persistence::MintDoor.names(settings)).to eq(["SchemaRevision.MintHeld"])
  end

  it "agrees with the bluebook, which no longer says mints_era" do
    settings = registry.binding_settings("Hecks", "persisted_by", "PostgresEra")
    expect { Hecks::Ports::Persistence::MintDoor.check!(hecks, settings) }.not_to raise_error
  end
end
