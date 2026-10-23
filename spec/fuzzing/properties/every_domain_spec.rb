require "spec_helper"
require "hecks/fuzzing"
require_relative "../../support/postgres_probe"

# The framework's storage guarantees over every example domain and the refusal fixture, each
# run on generated sequences: a record rebuilt from its journal equals the stored record, and
# folding the journal again changes nothing; a refusal leaves no trace; and Memory, SQLite and
# Postgres (behind `:io`) give the same outcomes for the same sequence. `PROPERTY_SEEDS` sets
# how many seeds each domain is replayed under.
RSpec.describe "every domain's stores", :aggregate_failures do
  def self.domains
    Hecks::Corpus.members(:example).map(&:path).sort + [File.join(InMemoryDomain::ROOT, "spec/fixtures/refusal_kinds")]
  end

  def self.seeds = 1..Integer(ENV.fetch("PROPERTY_SEEDS", "2"))

  def self.steps(dir, seed) = Hecks::Fuzzing::SequenceGenerator.generate(dir, seed: seed, steps: 25)

  # One replay per seed with the self-consistency checks run against its live runtime.
  def self.histories(dir)
    (@histories ||= {})[dir] ||= seeds.map { |seed| Hecks::Fuzzing::Replay.call(dir, steps(dir, seed), self_consistency: true) }
  end

  def journal_findings(dir)
    self.class.histories(dir).flat_map { |history| history[:self_consistency].values_at(:rehydration, :idempotency).flatten }
  end

  def refusal_findings(dir)
    self.class.histories(dir).map { |history| Hecks::Fuzzing::Properties.refusals_leave_no_trace(history) } - [true]
  end

  def parity_findings(dir, store, **storage)
    self.class.seeds.flat_map do |seed|
      Hecks::Fuzzing::PersistenceParity.diff(dir, self.class.steps(dir, seed), left: :memory, right: store, **storage)
    end
  end

  # Every adapter `dir`'s aggregates resolve to when booted against `store`.
  def bound_adapters(dir, store)
    Hecks::Fuzzing::IsolatedBoot.call(dir, adapter: store) do |copy|
      registry = Hecks.boot(copy, environment: nil).registry
      registry.bluebooks.flat_map do |name, bluebook|
        bluebook.aggregates.map { |aggregate| Hecks::Ports::Persistence::BindingPolicy.resolve(registry, name, aggregate).adapter }
      end.uniq
    end
  end

  domains.each do |dir|
    it "rebuilds #{File.basename(dir)}'s records from their journals, the same however often folded" do
      expect(journal_findings(dir)).to be_empty
    end

    it "leaves no trace of any refusal in #{File.basename(dir)}" do
      expect(refusal_findings(dir)).to be_empty
    end

    it "binds #{File.basename(dir)} to SQLite when asked, so the parity below compares two stores" do
      expect(bound_adapters(dir, :sqlite)).to eq(["SqlitePersistence"])
    end

    it "gives #{File.basename(dir)} the same outcomes on Memory and SQLite" do
      expect(parity_findings(dir, :sqlite)).to be_empty
    end

    it "gives #{File.basename(dir)} the same outcomes on Memory and Postgres", :io do
      skip "no reachable Postgres" unless PostgresProbe.available?

      expect(parity_findings(dir, :postgres)).to be_empty
    end
  end
end
