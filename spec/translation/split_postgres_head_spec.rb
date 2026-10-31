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

    attr_reader :db

    def eras = @eras
    def quoted_journal = "split_head_journal"
    def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"
  end

  before { skip "no local Postgres answers" unless PostgresProbe.available? }

  let(:db) { PG.connect(dbname: "postgres") }
  let(:host) { SplitHeadHost.new(db, [{ ordinal: 1, watermark: nil }, { ordinal: 2, watermark: nil }]) }
  let(:edges) { [{ translation: split_translation }] }
  let(:collection) { Struct.new(:name).new("Collection") }
  let(:layout) { Struct.new(:name).new("CollectionLayout") }

  let(:split_translation) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.data_translation("Shop", from: "aaa111", to: "bbb222") do
        aggregate("Collection") do
          drop :columns
          split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns]
        end
      end
    end
  end

  before do
    Hecks::Adapters::PostgresEra::Lineage::TransformSql::ALL.each { |sql| db.exec(sql) }
    db.exec("CREATE TEMP TABLE split_head_journal (ordinal bigserial, era integer, aggregate text, " \
            "aggregate_id text, operation text, state jsonb)")
    db.exec_params("INSERT INTO split_head_journal (era, aggregate, aggregate_id, operation, state) " \
                   "VALUES (1, 'collection', $1, 'save', $2::jsonb)",
                   ["A", JSON.generate("agg" => "A", "label" => "Board", "columns" => [{ "field" => "title" }])])
    db.exec_params("INSERT INTO split_head_journal (era, aggregate, aggregate_id, operation, state) " \
                   "VALUES (1, 'collection', $1, 'save', $2::jsonb)",
                   ["B", JSON.generate("agg" => "B", "label" => "Shelf", "columns" => [])])
  end

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
    db.exec_params("INSERT INTO split_head_journal (era, aggregate, aggregate_id, operation, state) " \
                   "VALUES (1, $1, $2, $3, $4::jsonb)",
                   ["collection", "B", "delete", JSON.generate("agg" => "B", "label" => "Shelf", "columns" => [])])
    heads = host.latest_of(host.chain_sql(layout, 2, edges))

    expect(heads.keys).to eq(["A"])
  end

  it "keeps the target's own rows from earlier eras, under the target's name" do
    db.exec_params("INSERT INTO split_head_journal (era, aggregate, aggregate_id, operation, state) " \
                   "VALUES (2, $1, $2, $3, $4::jsonb)",
                   ["collection_layout", "C", "save", JSON.generate("agg" => "C", "columns" => [])])
    later = [edges.first, { translation: layout_translation }]
    heads = host.latest_of(host.chain_sql(layout, 3, later))

    expect(heads.keys).to contain_exactly("A", "B", "C")
  end

  let(:layout_translation) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.data_translation("Shop", from: "bbb222", to: "ccc333") do
        aggregate("CollectionLayout") { rename :columns, to: :cols }
      end
    end
  end
end
