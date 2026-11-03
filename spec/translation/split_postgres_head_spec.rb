require "spec_helper"
require "pg"
require_relative "../support/postgres_probe"
require "hecks/adapters/driven/postgres_era/lineage"

# ADR 0166: a split target's head, read through the chain from a real journal. Each row is a
# Collection written in era 1; the split edge creates CollectionLayout in era 2 from the same rows.
RSpec.describe "a split target's head, read from the journal", :io do
  # Only what the chain reads from a Lineage: the journal's name, the eras and a connection.
  class SplitHeadHost
    include Hecks::Adapters::PostgresEra::Lineage::ChainSql

    def initialize(db, eras)
      @db = db
      @eras = eras
    end

    attr_reader :db, :eras

    def quoted_journal = "split_head_journal"
    def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"
  end

  before do
    skip "no local Postgres answers" unless PostgresProbe.available?
    Hecks::Adapters::PostgresEra::Lineage::TransformSql::ALL.each { |sql| db.exec(sql) }
    db.exec("CREATE TEMP TABLE split_head_journal (ordinal bigserial, era integer, aggregate text, " \
            "aggregate_id text, operation text, state jsonb)")
    journal_row(1, "collection", "A", "save", "agg" => "A", "label" => "Board",
                "columns" => [{ "field" => "title" }])
    journal_row(1, "collection", "B", "save", "agg" => "B", "label" => "Shelf", "columns" => [])
  end

  let(:db) { PG.connect(dbname: "postgres") }
  let(:host) { SplitHeadHost.new(db, [{ ordinal: 1, watermark: nil }, { ordinal: 2, watermark: nil }]) }
  let(:edges) { [{ translation: split_translation }] }

  after { db.close }

  it "fans the source's split fields out into one target row per key" do
    heads = host.latest_of(host.chain_sql(layout, 2, edges))

    expect(heads).to eq(
      "A" => { "columns" => [{ "field" => "title" }] },
      "B" => { "columns" => [] }
    )
  end

  it "keeps the source aggregate's own head, without the split fields" do
    heads = host.latest_of(host.chain_sql(collection, 2, edges))

    expect(heads).to eq(
      "A" => { "agg" => "A", "label" => "Board" },
      "B" => { "agg" => "B", "label" => "Shelf" }
    )
  end

  it "deletes the target row when its source row is deleted" do
    journal_row(1, "collection", "B", "delete", "agg" => "B", "label" => "Shelf", "columns" => [])
    heads = host.latest_of(host.chain_sql(layout, 2, edges))

    expect(heads.keys).to eq(["A"])
  end

  it "keeps the target's own rows from earlier eras, under the target's name" do
    journal_row(2, "collection_layout", "C", "save", "agg" => "C", "columns" => [])
    later = [edges.first, { translation: layout_translation }]
    heads = host.latest_of(host.chain_sql(layout, 3, later))

    expect(heads.keys).to contain_exactly("A", "B", "C")
  end

  it "keys a target by its source's value-object key, not the object" do
    journal_row(1, "collection", "D", "save", "agg" => { "value" => "D" }, "columns" => [{ "field" => "x" }])
    heads = host.latest_of(host.chain_sql(layout, 2, edges))

    expect(heads["D"]).to eq("columns" => [{ "field" => "x" }])
  end

  # @return [Struct] the source aggregate the chain reads rows of
  def collection = Struct.new(:name).new("Collection")

  # @return [Struct] the target aggregate the split creates
  def layout = Struct.new(:name).new("CollectionLayout")

  # Writes one row of the temporary journal the chain reads.
  def journal_row(era, aggregate, id, operation, state)
    db.exec_params("INSERT INTO split_head_journal (era, aggregate, aggregate_id, operation, state) " \
                   "VALUES ($1, $2, $3, $4, $5::jsonb)", [era, aggregate, id, operation, JSON.generate(state)])
  end

  def translation_between(from, to, &block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.data_translation("Shop", from: from, to: to, &block)
    end
  end

  def split_translation
    translation_between("aaa111", "bbb222") do
      aggregate("Collection") do
        drop :columns
        split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns]
      end
    end
  end

  def layout_translation
    translation_between("bbb222", "ccc333") { aggregate("CollectionLayout") { rename :columns, to: :cols } }
  end
end
