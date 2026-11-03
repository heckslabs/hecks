require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"

# The disposable ledger's archive moves an aggregate's journal rows without ever deleting a row it
# did not copy: the journal is locked against writers for the move, the delete must match the copy,
# an archive name that is taken gets a suffix, and the head view is swapped in one transaction.
RSpec.describe "a disposable ledger's archive on scratch Postgres", :io do
  include EraRegistryLoading

  ATOMIC_DB = "hecks_ledger_archive_atomicity_spec".freeze

  scratch_postgres ATOMIC_DB, fenced: true

  # Runs `block` between the archive's copy and its delete, inside the archive's own transaction.
  module BetweenCopyAndDelete
    attr_accessor :between

    private

    def delete_journal_rows!(storage_name)
      between&.call(@db)
      super
    end
  end

  # Records the transactions a lineage opens.
  module TransactionSpy
    def opened = (@opened ||= [])

    def nested_transaction(name, &)
      opened << name
      super
    end
  end

  ARCHIVE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      aggregate "Acct" do
        identified_by :kind
        attribute :kind, Kind
        attribute :name, Name
        value_object("Kind") { attribute :label, String }
        value_object("Name") { attribute :value, String }
      end
    end
  BLUEBOOK

  def url = FencedOwner.url(ATOMIC_DB)

  def bluebook = load_registry(ARCHIVE_SOURCE).bluebooks.values.first

  def settings = { database: url, disposable_ledger: true }

  def boot!
    registry = load_registry(ARCHIVE_SOURCE)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: ARCHIVE_SOURCE, settings: settings
    )
    registry
  end

  def adapter(registry)
    Hecks::Adapters::PostgresEra.new(
      aggregate: registry.bluebooks.values.first.aggregate("Acct"),
      settings:  { database: url, domain: "Ledger", era: registry.resolved_eras["Ledger"] }
    )
  end

  def append!(registry, id)
    state = { kind: { "label" => "biz" }, name: { "value" => id } }
    adapter(registry).append(Hecks::Ports::Persistence::Entry.new(operation: "save", id: id, state: state))
  end

  def sql(text)
    db = PG.connect(url)
    db.exec(text).to_a
  ensure
    db&.close
  end

  # A lineage on its own connection, with `between` hooked in before the delete.
  def lineage(between: nil)
    db = PG.connect(url)
    found = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    found.singleton_class.prepend(BetweenCopyAndDelete)
    found.between = between
    found
  end

  def ids(query) = sql(query).map { |row| row["aggregate_id"] }

  def journal_ids = ids("SELECT aggregate_id FROM hecks_journal_ledger WHERE aggregate = 'acct' ORDER BY ordinal")

  def archived_ids(archive) = ids(%(SELECT aggregate_id FROM "#{archive}"))

  def present?(name) = sql("SELECT to_regclass('#{name}') IS NOT NULL AS present").first["present"] == "t"

  # Archives with a writer that starts between the copy and the delete; answers the archive's name,
  # whether the writer was still waiting at the delete, and the writer's thread.
  def archive_with_writer
    writer = nil
    waited = nil
    mover = lineage(between: lambda { |_|
      writer = Thread.new { append!(@registry, "late") }
      waited = writer.join(1).nil?
    })
    [mover.archive_aggregate!("acct", STAMP).first, waited, writer.tap(&:join)]
  end

  # Archives with a row slipped into the journal, on the mover's own connection, before the delete.
  def archive_with_sneaked_row
    sneak = "INSERT INTO hecks_journal_ledger (era, aggregate, aggregate_id, state) VALUES (1, 'acct', 'sneak', '{}')"
    lineage(between: ->(db) { db.exec(sneak) }).archive_aggregate!("acct", STAMP)
  end

  STAMP = "20260101000000".freeze

  before do
    @registry = boot!
    append!(@registry, "first")
  end

  context "with a writer arriving between the copy and the delete" do
    before { @archive, @waited, = archive_with_writer }

    it("makes the writer wait for the move") { expect(@waited).to be(true) }
    it("keeps the writer's row in the journal") { expect(journal_ids).to eq(["late"]) }
    it("archives the row it copied") { expect(archived_ids(@archive)).to eq(["first"]) }
  end

  context "with a delete that would remove a row the copy lacks" do
    it "refuses, naming that nothing was moved" do
      expect { archive_with_sneaked_row }.to raise_error(Hecks::Runtime::WiringError, /nothing was moved/)
    end

    it "leaves the journal and the archive list as they were", :aggregate_failures do
      expect { archive_with_sneaked_row }.to raise_error(Hecks::Runtime::WiringError)
      expect([journal_ids, present?("ledger_acct_archived_#{STAMP}")]).to eq([%w[first], false])
    end
  end

  context "with an archive made in the same second as another" do
    before do
      @first, = lineage.archive_aggregate!("acct", STAMP)
      append!(@registry, "second")
      @second, = lineage.archive_aggregate!("acct", STAMP)
    end

    it "suffixes the second" do
      expect([@first, @second]).to eq(["ledger_acct_archived_#{STAMP}", "ledger_acct_archived_#{STAMP}_2"])
    end

    it("never overwrites the first") { expect(archived_ids(@first)).to eq(["first"]) }
  end

  context "when the head view is replaced" do
    before do
      @mover = lineage
      @mover.singleton_class.prepend(TransactionSpy)
      @mover.fresh_head!("acct", 1)
    end

    it("does so inside one transaction") { expect(@mover.opened).to eq(["hecks_fresh_head"]) }
    it("leaves the view in place") { expect(present?("ledger_acct_head")).to be(true) }
  end
end
