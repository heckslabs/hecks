require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/direct_chains"

# Proves the direct head (one composed step per held era) equals the chain (one link per era)
# for every committed edge chain, over rows built from each ruled aggregate's held shape.
# A chain that has no exact composition (a rekey) reads through the chain, and says so.
RSpec.describe "PostgresRevision direct translation against the edge chain", :io do
  DIRECT_DB = "hecks_postgres_era_direct_spec".freeze
  Aggregate = Struct.new(:name, :storage_name)

  scratch_postgres DIRECT_DB

  # The lineage surface the head SQL reads, over a scratch journal.
  class DirectHost
    include Hecks::Adapters::PostgresRevision::Lineage::ChainSql

    def initialize(db) = @db = db
    def eras = []
    def quoted_journal = "journal"
    def text_literal(text) = "'#{text}'"
  end

  def self.edges_by_domain = DirectChains.edges_by_domain

  def self.chains = DirectChains.chains

  def database
    @database ||= PG.connect(dbname: DIRECT_DB).tap do |db|
      db.exec("CREATE TABLE journal (ordinal bigint, era int, aggregate text, aggregate_id text, " \
              "operation text, state jsonb)")
      Hecks::Adapters::PostgresRevision::Lineage::TransformSql::ALL.each { |sql| db.exec(sql) }
    end
  end

  after { @database&.close }

  # The field paths the chain's rules read, which the held rows must carry.
  def sources_of(chain, name)
    rules = chain.flat_map(&:aggregates).select { |aggregate| [aggregate.name, aggregate.was].include?(name) }
    rules.flat_map { |rule| rule_paths(rule) }.map(&:to_s)
  end

  def rule_paths(rule)
    expressions = rule.derives.flat_map { |derive| derive.expression.to_s.scan(/[a-z_]+(?:\.[a-z_]+)*/) }
    rule.renames.keys + rule.moves.map(&:from) + rule.drops + expressions
  end

  def nest(path, value) = path.split(".").reverse.inject(value) { |inner, key| { key => inner } }

  def deep_merge(left, right) = left.merge(right) { |_, a, b| a.is_a?(Hash) ? deep_merge(a, b) : b }

  def row_for(chain, name, era)
    parts = sources_of(chain, name).map { |path| nest(path, "v#{era}") }
    parts.inject({ "bystander" => "keep#{era}" }) { |row, part| deep_merge(row, part) }
  end

  def insert(ordinal, era, storage, id, row)
    database.exec_params("INSERT INTO journal VALUES ($1, $2, $3, $4, $5, $6)",
                         [ordinal, era, storage, id, row ? "save" : "delete", row&.to_json])
  end

  # Each era writes a superseded save, a live save, and (in even eras) a delete.
  def load_journal(host, chain, aggregate)
    names = host.names_by_era(aggregate, chain.map { |edge| { translation: edge } })
    (1..chain.size).each { |era| load_era(chain, aggregate.name, era, names[:storage][era - 1]) }
  end

  def load_era(chain, name, era, storage)
    state = row_for(chain, name, era)
    rows = [["1", state.merge("old" => true)], ["2", state], ["3", era.even? ? nil : state]]
    rows.each_with_index { |(id, row), at| insert((era * 10) + at, era, storage, "#{id}-#{era}", row) }
  end

  # The names to read: every final aggregate name the chain ends on, and one it never touches.
  def names_in(chain)
    (chain.flat_map { |edge| edge.aggregates.map(&:name) } + ["Zebra"]).uniq
  end

  # [direct rows, chain rows, whether a direct form exists] for one aggregate.
  def read_both(host, chain, name)
    aggregate = Aggregate.new(name, Hecks::Naming.snake(name))
    edges = chain.map { |edge| { translation: edge } }
    database.exec("TRUNCATE journal")
    load_journal(host, chain, aggregate)
    sql = host.direct_chain_sql(aggregate, chain.size + 1, edges)
    by_chain = host.latest_of(host.chain_sql(aggregate, chain.size + 1, edges))
    [sql && host.latest_of(sql), by_chain, !sql.nil?]
  end

  def readings(chain) = names_in(chain).map { |name| read_both(DirectHost.new(database), chain, name) }

  chains.each do |domain, start, final, chain|
    it "#{domain} #{start} to #{final} reads the same direct as by chain" do
      expect(readings(chain)).to all(satisfy { |direct, by_chain| direct == by_chain && !by_chain.empty? })
    end
  end

  it "refuses a direct form where a rekey has no composition" do
    chain = self.class.edges_by_domain.fetch("Directory")
    expect(readings(chain).map(&:last).uniq).to eq([false])
  end

  # A one-step edge declared here: the committed edges hold no plain rename to read.
  def rename_edge
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.data_translation("Composer", from: "aaaaaa", to: "bbbbbb") do
        aggregate("Draft") { rename :chapter_name, to: :bluebook_name }
      end
    end
    registry.translations.first
  end

  it "carries a rename that only the rules know" do
    edges = [{ translation: rename_edge }]
    database.exec("INSERT INTO journal VALUES (1, 1, 'draft', 'a', 'save', '{\"chapter_name\":\"x\"}')")
    sql = DirectHost.new(database).direct_chain_sql(Aggregate.new("Draft", "draft"), 2, edges)
    expect(DirectHost.new(database).latest_of(sql)).to eq("a" => { "bluebook_name" => "x" })
  end
end
