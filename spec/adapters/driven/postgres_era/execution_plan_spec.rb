require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/persistence_adapter_examples"
require_relative "../../../support/first_era_hold"

RSpec.describe "PostgresRevision execution-plan capabilities", :io do
  include_context "with the atomic_put Item aggregate"
  include FirstEraHold

  # Not SPEC_DB — a constant assigned inside an RSpec.describe block lands
  # at top level (load_hygiene_spec.rb's own "lets no two spec files
  # disagree about a top-level constant"), and postgres_era_spec.rb
  # already claims that name for a different database.
  EXECUTION_PLAN_DB = "hecks_postgres_era_execution_plan_spec".freeze

  scratch_postgres EXECUTION_PLAN_DB

  let(:aggregate) { item_aggregate("PostgresEraPlanning", "PostgresRevision implements the frozen atomic-put contract") }
  # The Item bluebook the first era freezes; the adapter reads the era, never its text.
  let(:source) do
    <<~BLUEBOOK
      Hecks.bluebook "PostgresEraPlanning" do
        aggregate "Item" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end
  let(:store) do
    adapter = Hecks::Adapters::PostgresRevision.new(
      aggregate: aggregate,
      settings:  { database: EXECUTION_PLAN_DB, domain: "PostgresEraPlanning" }
    )
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  before { hold_first_era!(url: EXECUTION_PLAN_DB, domain: "PostgresEraPlanning", source: source) }

  it "reports the capabilities it has" do
    expect(store.capabilities).to eq(%i[atomic_put cross_process_lock atomic_append dispatch_claims])
  end

  it_behaves_like "an atomic_put adapter"
end
