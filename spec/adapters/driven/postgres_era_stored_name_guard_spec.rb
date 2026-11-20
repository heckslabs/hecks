require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"
require_relative "../../support/first_era_hold"

# The data-loss case on PostgresEra: a rename whose stored name stops reaching the journal rows the
# aggregate was written under would boot onto a name that holds nothing, and the rows would seem
# gone. The boot refuses by name. Runs only when a Postgres server is reachable.
RSpec.describe "the PostgresEra stored-name guard", :io do
  include FirstEraHold

  NAME_GUARD_DB = "hecks_era_name_guard_spec".freeze
  NAME_GUARD_JOURNAL = "hecks_journal_pizzas".freeze

  scratch_postgres NAME_GUARD_DB

  let(:aggregate) { boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  before do
    hold_first_era!(url: NAME_GUARD_DB, domain: "Pizzas", source: File.read(InMemoryDomain::PIZZAS_BLUEBOOK))
  end

  def journal_rows_under(name, rows: 1)
    db = PG.connect(dbname: NAME_GUARD_DB)
    insert = %(INSERT INTO "#{NAME_GUARD_JOURNAL}" (era, aggregate, aggregate_id, state) VALUES (1, $1, $2, '{}'))
    rows.times { |i| db.exec_params(insert, [name, "r#{i}"]) }
  ensure
    db&.close
  end

  def boot
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: NAME_GUARD_DB, domain: "Pizzas" })
  end

  it "refuses to boot onto a name that holds no rows beside the rows the former name holds" do
    journal_rows_under("commit")
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.to raise_error(Hecks::Runtime::WiringError, /Order.*"commit".*holds rows.*stored_as/m)
  end

  it "boots when the world points the aggregate at the name the rows are under" do
    journal_rows_under("commit")
    aggregate.stored_as = "commit"
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.not_to raise_error
  end

  it "boots when its own name holds rows too" do
    journal_rows_under("commit")
    journal_rows_under("order")
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.not_to raise_error
  end

  it "boots when the former name holds no rows" do
    aggregate.prior_storage_names = ["commit"]
    expect { boot }.not_to raise_error
  end

  it "boots when the aggregate has no prior names" do
    journal_rows_under("commit")
    expect { boot }.not_to raise_error
  end
end
