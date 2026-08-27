require "hecks"
require "hecks/ports/persistence/plugins/era"

# `EraResolver.check!`'s own `role` lookup — deliberately NOT `io: true`:
# every collaborator that would otherwise need a real Postgres connection
# (connect_for, Lineage) is doubled, so this isolates exactly the one
# thing under test — which settings spelling `role` resolves to — without
# needing a live database.
#
# `role` only ever grants privileges when truthy (`grant_role!(...) if
# role`), so a `false` role and an absent one are downstream-equivalent —
# EXCEPT at the moment of resolution itself: the old `settings[:role] ||
# settings["role"]` would silently substitute the STRING spelling's value
# whenever the symbol spelling held `false`, granting a role nobody asked
# for. That substitution is exactly what this proves does not happen.
RSpec.describe "Hecks::Adapters::PostgresEra::LineageManager::EraResolver — role resolution" do
  let(:lineage) { instance_double(Hecks::Adapters::PostgresEra::Lineage, ensure_base!: nil, eras: [], hold_first!: nil, ensure_first_head!: nil, grant_role!: nil) }
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
    expect(lineage).to receive(:grant_role!).with("reader", aggregates: [], era: 1)

    check!(role: "reader", "role" => "writer")
  end

  it "grants NO role when the symbol spelling is genuinely `false`, rather than falling to the string spelling" do
    expect(lineage).not_to receive(:grant_role!)

    check!(role: false, "role" => "writer")
  end

  it "falls to the string spelling only when the symbol key is genuinely absent" do
    expect(lineage).to receive(:grant_role!).with("writer", aggregates: [], era: 1)

    check!("role" => "writer")
  end
end
