require "spec_helper"
require "json"
require "hecks/fuzzing"
require_relative "support/postgres_probe"
require_relative "support/scratch_postgres"

# A query argument whose value does not match its declared type is refused with TypeMismatch
# before any store is read, worded as a command argument of that type is. Memory and
# PostgresEra refuse the same query the same way; the parity example at the bottom holds them to it.
RSpec.describe "a query argument of the wrong shape" do
  QUERY_ARGUMENT_SHAPE_DB = "hecks_query_argument_shape_spec".freeze

  QUERY_ARGUMENT_SHAPE_QUERY = "QueryArgumentShape::Note.About".freeze

  # A Hash offered for a String argument: the wording a command's String argument gets for the same.
  QUERY_ARGUMENT_SHAPE_REFUSAL = 'Note.subject_id expects String, got {"cents":0}'.freeze

  def self.fixture = File.join(InMemoryDomain::ROOT, "spec/fixtures/query_argument_shape")

  def self.steps = JSON.parse(File.read(File.join(fixture, "steps.json")))["steps"]

  def memory_history = @memory_history ||= Hecks::Fuzzing::Replay.call(self.class.fixture, self.class.steps)

  def memory_entry = memory_history[:queries].find { |entry| entry[:query] == QUERY_ARGUMENT_SHAPE_QUERY }

  def refusals_of(history) = history[:refusals].map { |refusal| refusal.slice(:verb, :error, :kind) }

  describe "on Memory" do
    it "refuses the query as a TypeMismatch naming the argument and the offered value" do
      expect(refusals_of(memory_history)).to eq(
        [{ verb: QUERY_ARGUMENT_SHAPE_QUERY, error: QUERY_ARGUMENT_SHAPE_REFUSAL, kind: "Hecks::Runtime::TypeMismatch" }]
      )
    end

    it "carries the same refusal on the query log entry, with no rows" do
      expect(memory_entry).to include(error: QUERY_ARGUMENT_SHAPE_REFUSAL)
    end
  end

  describe "on PostgresEra", :io do
    before(:context) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      ScratchPostgres.create([QUERY_ARGUMENT_SHAPE_DB])
    end

    after(:context) { ScratchPostgres.drop([QUERY_ARGUMENT_SHAPE_DB]) if PostgresProbe.available? }

    before { ScratchPostgres.scrub([QUERY_ARGUMENT_SHAPE_DB]) if PostgresProbe.available? }

    def postgres_history
      Hecks::Fuzzing::Replay.call(self.class.fixture, self.class.steps,
                                  adapter: :postgres_era, database: QUERY_ARGUMENT_SHAPE_DB, schema: "public")
    end

    it "refuses the same query as Memory, without a driver error" do
      expect(refusals_of(postgres_history)).to eq(refusals_of(memory_history))
    end

    it "agrees with Memory on every answer, through the persistence parity check" do
      diff = Hecks::Fuzzing::PersistenceParity.diff(self.class.fixture, self.class.steps,
                                                    left: :memory, right: :postgres_era,
                                                    database: QUERY_ARGUMENT_SHAPE_DB, schema: "public")
      expect(diff).to be_empty
    end
  end
end
