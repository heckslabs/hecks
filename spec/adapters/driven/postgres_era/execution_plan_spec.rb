require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"

RSpec.describe "PostgresEra execution-plan capabilities", :io do
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

  def item_aggregate
    Hecks::Bluebook::DSL::BluebookBuilder.build("PostgresEraPlanning") do
      vision "PostgresEra implements the frozen atomic-put contract"

      aggregate "Item" do
        identified_by do
          attribute :sku, String
        end

        value_object("Label") { attribute :value, String }
        attribute :label, Label
      end
    end.aggregate("Item")
  end

  let(:aggregate) { item_aggregate }
  let(:repository) do
    adapter = Hecks::Adapters::PostgresEra.new(
      aggregate: aggregate,
      settings:  { database: EXECUTION_PLAN_DB, domain: "PostgresEraPlanning" }
    )
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  def item_labelled(value)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: value } }
    )
  end

  it "reports the capabilities it has" do
    expect(repository.capabilities).to eq(%i[atomic_put cross_process_lock atomic_append])
  end

  it "reports an insert for the first put of an identity" do
    expect(repository.atomic_put(item_labelled("First")).status).to eq(:inserted)
  end

  it "reports a replacement for the second put of an identity" do
    repository.atomic_put(item_labelled("First"))

    expect(repository.atomic_put(item_labelled("Second")).status).to eq(:replaced)
  end

  it "appends every put, and finds the latest" do
    repository.atomic_put(item_labelled("First"))
    repository.atomic_put(item_labelled("Second"))

    expect([repository.entries.size, repository.find("sku-1").state[:label].to_h]).to eq([2, { value: "Second" }])
  end
end
