require "hecksagain"
require_relative "../../../support/postgres_probe"

RSpec.describe "PostgresEra execution-plan capabilities", io: true do
  # Not SPEC_DB — a constant assigned inside an RSpec.describe block lands
  # at TOP LEVEL (load_hygiene_spec.rb's own "lets no two spec files
  # disagree about a top-level constant"), and postgres_era_spec.rb
  # already claims that name for a different database.
  EXECUTION_PLAN_DB = "hecksagain_postgres_era_execution_plan_spec".freeze

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
    Hecksagain::Bluebook::DSL::BluebookBuilder.build("PostgresEraPlanning") do
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

  it "atomically appends and projects while reporting insert versus replacement" do
    aggregate = item_aggregate
    adapter = Hecksagain::Adapters::PostgresEra.new(
      aggregate: aggregate,
      settings:  { database: EXECUTION_PLAN_DB, domain: "PostgresEraPlanning" }
    )
    repository = Hecksagain::Ports::Persistence::AppendOnly.new(adapter)

    first = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    second = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: "Second" } }
    )

    expect(repository.capabilities).to eq([:atomic_put])
    expect(repository.atomic_put(first).status).to eq(:inserted)
    expect(repository.atomic_put(second).status).to eq(:replaced)
    expect(repository.entries.size).to eq(2)
    expect(repository.find("sku-1").state[:label].to_h).to eq(value: "Second")
  end
end
