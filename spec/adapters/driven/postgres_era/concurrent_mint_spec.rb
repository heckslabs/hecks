require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/thread_parking"
require_relative "../../../support/mint_request_support"
require_relative "../../../support/first_era_hold"

# Two minters decide to mint the same era 2 against the same held era 1, then race the commit.
# The schedule is forced, not hoped for: the first minter is parked inside its mint transaction
# (it holds the domain's advisory lock, its era row is written but uncommitted), the second is let
# in and observed blocked on that lock, and only then is the first released.
#
# The seam is `Lineage::MintTransaction#materialize_era!`, an existing private step of the mint.
# `Gate` is prepended once and is inert unless a spec arms it, so production behaviour is untouched.
RSpec.describe "two concurrent mints of one era in the PostgresEra adapter", :io do
  include EraRegistryLoading
  include MintRequestSupport
  include FirstEraHold

  MINT_RACE_DB = "hecks_concurrent_mint_spec".freeze
  MINT_RACE_OWNER = "hecks_concurrent_mint_owner".freeze

  # Parks the first thread to enter `materialize_era!` until released; every other caller runs free.
  module Gate
    @mutex = Mutex.new

    class << self
      attr_reader :parked

      # @return [Queue] pushed to when the first minter is parked inside its transaction
      def arm!
        @mutex.synchronize do
          @first = nil
          @armed = true
          @parked = Queue.new
          @release = Queue.new
        end
        @parked
      end

      def release! = @release << true

      def disarm! = @mutex.synchronize { @armed = false }

      # @return [Boolean] true for exactly the first caller after `arm!`
      def first_entrant?
        @mutex.synchronize do
          next false unless @armed && @first.nil?

          @first = Thread.current
          true
        end
      end

      def park!
        @parked << true
        @release.pop
      end
    end

    def materialize_era!(mint)
      Gate.park! if Gate.first_entrant?
      super
    end
  end
  Hecks::Adapters::PostgresEra::Lineage.prepend(Gate)

  V1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Acct" do
        identified_by :kind
        attribute :cost, Money
        attribute :kind, Kind
        value_object "Money" do
          attribute :cents, Integer
        end
        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  V2_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Account" do
        identified_by :kind
        attribute :amount, Money
        attribute :kind, Kind
        value_object "Money" do
          attribute :cents, Integer
        end
        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  def owner_url = "postgres://#{MINT_RACE_OWNER}@localhost/#{MINT_RACE_DB}"
  def with_db(**, &) = with_pg(dbname: MINT_RACE_DB, **, &)

  def with_pg(*, **)
    db = PG.connect(*, **)
    yield db
  ensure
    db&.close
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{MINT_RACE_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{MINT_RACE_DB}")
    admin.exec("DROP ROLE IF EXISTS #{MINT_RACE_OWNER}")
    admin.exec("CREATE ROLE #{MINT_RACE_OWNER} LOGIN")
    admin.close
    grant = PG.connect(dbname: MINT_RACE_DB)
    grant.exec("GRANT CONNECT ON DATABASE #{MINT_RACE_DB} TO #{MINT_RACE_OWNER}")
    grant.close
  end

  after(:all) do
    Gate.disarm!
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{MINT_RACE_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: MINT_RACE_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{MINT_RACE_OWNER}")
    scrub.close
  end

  after { Gate.disarm! }

  def hash_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)
  end

  # The one edge from V1 to V2: Acct becomes Account and its cost field is renamed amount.
  def edge_source(from:, to:)
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
        aggregate("Account", was: "Acct") do
          rename :cost, to: :amount
        end
      end
    RUBY
  end

  def v1_to_v2_edge = edge_source(from: hash_of(V1_SOURCE)[0, 6], to: hash_of(V2_SOURCE)[0, 6])

  # One full boot-time era check of V2 against the database, minting if drifted.
  def mint_v2!
    hold_first_era!(url: owner_url, domain: "Ledger", source: V1_SOURCE) unless first_era_held?
    registry = load_registry(V2_SOURCE, translation_source: v1_to_v2_edge)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: V2_SOURCE,
      settings: with_mint_request({ database: owner_url, mint_eras: true }, domain: "Ledger")
    )
  end

  def first_era_held?
    with_db do |db|
      next false unless db.exec("SELECT to_regclass('hecks_eras') AS t")[0]["t"]

      db.exec("SELECT 1 FROM hecks_eras WHERE domain = 'Ledger' LIMIT 1").ntuples.positive?
    end
  end

  # The statement a backend is blocked on behind a lock, or nil: the second minter is queued
  # behind the parked first one. Asked of Postgres itself, so there is no guessed sleep.
  def blocked_statement
    with_db do |db|
      db.exec("SELECT query FROM pg_stat_activity WHERE datname = current_database() " \
              "AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()").first&.fetch("query")
    end
  end

  # Runs the forced schedule and answers what each minter returned, in start order.
  #
  #   A: decide ── lock ── insert ── PARK ───────────────── release ── commit
  #   B:                       decide ── lock (blocks) ───────────────────── re-check ── stand down
  def race_two_mints!
    hold_first_era!(url: owner_url, domain: "Ledger", source: V1_SOURCE) unless first_era_held?
    parked = Gate.arm!
    outcomes = {}
    first = start_first_minter(parked, outcomes)
    second = Thread.new { outcomes[:second] = capture { mint_v2! } }
    ThreadParking.wait_for { outcomes[:blocked_on] = blocked_statement }
    Gate.release!
    [first, second].each(&:join)
    outcomes
  end

  # Starts the first minter and waits until it is parked inside its transaction.
  def start_first_minter(parked, outcomes)
    first = Thread.new { outcomes[:first] = capture { mint_v2! } }
    ThreadParking.wait_for { !parked.empty? || !first.alive? }
    raise "the first minter finished before reaching the gate: #{outcomes[:first].inspect}" if parked.empty?

    first
  end

  def capture
    { returned: yield }
  rescue StandardError => e
    { raised: e }
  end

  def eras = with_db { |db| db.exec("SELECT ordinal, hash FROM hecks_eras WHERE domain = 'Ledger' ORDER BY ordinal").to_a }

  def era_partitions
    with_db do |db|
      db.exec("SELECT count(*) FROM pg_inherits WHERE inhparent = 'hecks_journal_ledger'::regclass")[0]["count"].to_i
    end
  end

  # The same schedule, three times from a clean database: a reproduced schedule, not a lucky one.
  3.times do |run|
    context "with run #{run + 1} of the forced schedule" do
      let!(:outcomes) { race_two_mints! }

      it "commits era 2 exactly once", :aggregate_failures do
        expect(eras.map { |era| era["ordinal"] }).to eq(%w[1 2])
        expect(eras.last["hash"]).to eq(hash_of(V2_SOURCE))
      end

      it "leaves one partition per era, not one per attempt" do
        expect(era_partitions).to eq(2)
      end

      it "lets both callers finish: the loser stands down after the winner commits", :aggregate_failures do
        expect(outcomes[:first]).to include(:returned)
        expect(outcomes[:second]).to include(:returned)
      end

      # The loser queues behind the winner's uncommitted insert in boot-time upkeep, before it
      # decides anything; once the winner commits it finds the shape held and mints nothing.
      it "makes the loser wait on the winner's uncommitted era row, then boot without minting", :aggregate_failures do
        expect(outcomes[:blocked_on]).to include("hecks_eras")
        expect(outcomes[:first][:returned]).to eq(2)
        expect(outcomes[:second][:returned]).to be_nil
      end
    end
  end
end
