require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"

RSpec.describe "PostgresEra chain SQL over a long edge chain", :io do
  # Not SPEC_DB: a describe-block constant lands at top level, and other specs claim that name.
  CHAIN_LIMIT_DB = "hecks_postgres_era_chain_limit_spec".freeze

  scratch_postgres CHAIN_LIMIT_DB

  # An edge rule reads `state` twice, as a backfill or derive does.
  READS_TWICE = "(SELECT CASE WHEN (SELECT state ? 'a') THEN __s ELSE __s || '{}'::jsonb END " \
                "FROM (SELECT (state) AS __s) __outer)".freeze

  let(:host) do
    Class.new do
      include Hecks::Adapters::PostgresEra::Lineage::ChainSql

      def eras = []
      def quoted_journal = "chain_journal"
      def text_literal(text) = "'#{text}'"
      def rules_expression(_declared) = READS_TWICE
    end.new
  end

  def chain_of(count)
    edge = { translation: Struct.new(:none) { def for_aggregate(_name) = nil }.new }
    host.chain_sql(Struct.new(:name).new("Item"), count + 1, Array.new(count) { edge })
  end

  def plan(sql)
    db = PG.connect(dbname: CHAIN_LIMIT_DB)
    db.exec("CREATE TABLE chain_journal (ordinal bigint, era int, aggregate text, aggregate_id text, " \
            "operation text, state jsonb)")
    db.exec("EXPLAIN #{sql}")
  ensure
    db&.close
  end

  it "plans ten edges that each read state twice" do
    expect { plan(chain_of(10)) }.not_to raise_error
  end
end
