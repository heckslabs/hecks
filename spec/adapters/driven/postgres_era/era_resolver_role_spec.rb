require "hecks"
require "hecks/ports/persistence/plugins/era"

# Which settings spelling `EraResolver.check!` resolves `role` from. Postgres
# collaborators are doubled, so no live database is needed.
# Pins that a `false` symbol-keyed role does not fall through to the string key.
RSpec.describe "Hecks::Adapters::PostgresEra::LineageManager::EraResolver — role resolution" do
  let(:lineage) do
    instance_double(Hecks::Adapters::PostgresEra::Lineage, check_fence_applies!: nil, ensure_base!: nil, eras: [],
                                                             hold_first!: nil, ensure_first_head!: nil, grant_role!: nil)
  end
  let(:registry) { Hecks::Runtime::Registry.new }
  let(:bluebook) { double("bluebook", name: "Widgets", formerly_known_as: nil, aggregates: []) } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Hecks::Adapters::PostgresEra).to receive(:connect_for).and_return(double("db", close: nil)) # rubocop:disable RSpec/VerifiedDoubles
    allow(Hecks::Adapters::PostgresEra::Lineage).to receive(:new).and_return(lineage)
    allow(Hecks::Runtime::StorageShape).to receive(:project).and_return({})
  end

  def check!(settings)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: "Hecks.bluebook \"Widgets\" do end", settings: settings
    )
  end

  it "grants the symbol-keyed role even when the string spelling also holds a value" do
    check!(role: "reader", "role" => "writer")

    expect(lineage).to have_received(:grant_role!).with("reader", aggregates: [], era: 1)
  end

  it "grants NO role when the symbol spelling is genuinely `false`, rather than falling to the string spelling" do
    check!(role: false, "role" => "writer")

    expect(lineage).not_to have_received(:grant_role!)
  end

  it "falls to the string spelling only when the symbol key is genuinely absent" do
    check!("role" => "writer")

    expect(lineage).to have_received(:grant_role!).with("writer", aggregates: [], era: 1)
  end
end
