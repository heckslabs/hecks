require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/persistence_adapter_examples"

RSpec.describe "PostgresEra execution-plan capabilities", :io do
  include_context "with the atomic_put Item aggregate"

  # Not SPEC_DB — a constant assigned inside an RSpec.describe block lands
  # at top level (load_hygiene_spec.rb's own "lets no two spec files
  # disagree about a top-level constant"), and postgres_era_spec.rb
  # already claims that name for a different database.
  EXECUTION_PLAN_DB = "hecks_postgres_era_execution_plan_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{EXECUTION_PLAN_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{EXECUTION_PLAN_DB}")
    admin.close
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{EXECUTION_PLAN_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: EXECUTION_PLAN_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  let(:aggregate) { item_aggregate("PostgresEraPlanning", "PostgresEra implements the frozen atomic-put contract") }
  let(:store) do
    adapter = Hecks::Adapters::PostgresEra.new(
      aggregate: aggregate,
      settings:  { database: EXECUTION_PLAN_DB, domain: "PostgresEraPlanning" }
    )
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  it "reports the capabilities it has" do
    expect(store.capabilities).to eq(%i[atomic_put cross_process_lock atomic_append])
  end

  it_behaves_like "an atomic_put adapter"
end
