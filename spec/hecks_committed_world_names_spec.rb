require "hecks"

# The Hecks domain keeps its renamed aggregates in the tables they were written to, and names its
# mint command, in the world that is committed. A development checkout keeps its persistence in
# local files, so these two facts cannot live there.
RSpec.describe "the Hecks domain's committed world names" do
  let(:registry) do
    Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__)).registry.tap(&:apply_world_names!)
  end
  let(:hecks) { registry.bluebook("Hecks") }

  it "stores each renamed aggregate under the table its earlier name wrote" do
    stored = %w[Workspace SendTrain ReviewRequest].to_h { |name| [name, hecks.aggregate(name).storage_name] }
    expect(stored).to eq("Workspace" => "checkout", "SendTrain" => "push_train", "ReviewRequest" => "pull_request")
  end

  it "stores the delivery package's Revision under the table its earlier name wrote" do
    expect(registry.bluebook("Delivery").aggregate("Revision").storage_name).to eq("commit")
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
