require "hecks"
require "hecks/ports/persistence/plugins/era"
require "pg"

# A boot never grants a role: the grant is a catalog write, so it belongs to the mint entry point,
# which grants the role on the era it mints. Postgres collaborators are doubled, so no live database
# is needed. Pins that no settings spelling of `role` reaches `grant_role!` from a boot.
RSpec.describe "Hecks::Adapters::PostgresEra::LineageManager::RevisionResolver — role on boot" do
  let(:held) { [{ ordinal: 1, label: "abc123", projection: {}, held_text: %(Hecks.bluebook "Widgets" do end) }] }
  let(:lineage) do
    instance_double(Hecks::Adapters::PostgresEra::Lineage, check_fence_applies!: nil, ensure_base!: nil,
                                                             refuse_pending_rename!: nil, eras: held, grant_role!: nil)
  end
  let(:registry) { Hecks::Runtime::Registry.new }
  let(:bluebook) { instance_double(Hecks::Bluebook::Declaration, name: "Widgets", formerly_known_as: nil, aggregates: []) }

  before do
    allow(Hecks::Adapters::PostgresEra).to receive(:connect_for).and_return(instance_double(PG::Connection, close: nil))
    allow(Hecks::Adapters::PostgresEra::Lineage).to receive(:new).and_return(lineage)
    allow(Hecks::Runtime::StorageShape).to receive(:project).and_return({})
  end

  def check!(settings)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: "Hecks.bluebook \"Widgets\" do end", settings: settings
    )
  end

  it "grants no role on boot when the symbol spelling names one" do
    check!(role: "reader", "role" => "writer")

    expect(lineage).not_to have_received(:grant_role!)
  end

  it "grants no role on boot when the symbol spelling is genuinely `false`" do
    check!(role: false, "role" => "writer")

    expect(lineage).not_to have_received(:grant_role!)
  end

  it "grants no role on boot when only the string spelling names one" do
    check!("role" => "writer")

    expect(lineage).not_to have_received(:grant_role!)
  end
end
