require "hecks/fuzzing/concurrent_dispatch"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"

# `Hecks::Fuzzing::ConcurrentDispatch` against the real cross-process lock. Proves the pure
# comparison (`divergences_for`, synthetic outcomes, no Postgres) and, separately, the forked
# real-Postgres pipeline agreeing with its sequential oracle on a conflicting pair (ADR 0036).
RSpec.describe Hecks::Fuzzing::ConcurrentDispatch do
  # A broken probe is not a sequence with nothing to race: answering `[]` would log a clean
  # concurrency Check while the race never ran. No Postgres: refusal happens before boot.
  describe ".check, when the cross-process-lock probe itself fails" do
    it "reports it rather than answering clean" do
      allow(described_class).to receive(:lockable_verbs).and_return([[], ["Shop::Order.Place: NoMethodError: boom"]])

      divergences = described_class.check("examples/pizzas", [{ "verb" => "Shop::Order.Place" }],
                                          database: "unused", race_schema: "unused", reference_schema: "unused")

      expect(divergences.map { |divergence| divergence[:field] }).to eq(["concurrency_unraceable"])
      expect(divergences.first[:detail]).to include("NoMethodError: boom")
    end

    it "still answers clean when nothing raced because there was nothing to race" do
      allow(described_class).to receive(:lockable_verbs).and_return([[], []])

      expect(described_class.check("examples/pizzas", [{ "query" => "Order::All" }],
                                   database: "unused", race_schema: "unused", reference_schema: "unused")).to eq([])
    end
  end

  describe ".pick_race_index" do
    def step(verb) = { "verb" => verb }
    def query_step = { "verb" => nil, "query" => "Widget::All" }
    def dry_run_step(verb) = { "verb" => verb, "dry_run" => true }

    it "returns nil when the sequence has no command step at all" do
      expect(described_class.pick_race_index([query_step, query_step])).to be_nil
    end

    it "picks the command step closest to the middle, ignoring query/dry-run steps" do
      steps = [step("A"), query_step, step("B"), dry_run_step("C"), step("D")]
      # command indices: 0, 2, 4 -> middle of [0,2,4] (size 3, 3/2=1) -> index 2
      expect(described_class.pick_race_index(steps)).to eq(2)
    end

    it "can pick index 0 — racing a bare identity-creation with no setup at all is legitimate" do
      expect(described_class.pick_race_index([step("Open")])).to eq(0)
    end
  end

  describe ".divergences_for" do
    let(:race_step) { { "verb" => "Account.Debit" } }

    it "is clean when the concurrent pair settles on the same outcomes the oracle does, any order" do
      divergences = described_class.divergences_for(race_step, %w[succeeded refused], %w[refused succeeded])

      expect(divergences).to eq([])
    end

    it "flags a lost update — the concurrent pair agrees on an outcome multiset the oracle never produced" do
      divergences = described_class.divergences_for(race_step, %w[succeeded refused], %w[succeeded succeeded])

      expect(divergences.size).to eq(1)
      expect(divergences.first[:field]).to eq("concurrency_race")
      expect(divergences.first[:reference]).to eq(%w[succeeded refused])
      expect(divergences.first[:concurrent]).to eq(%w[succeeded succeeded])
    end

    it "flags a crash in either racer as its own finding, distinct from a race mismatch" do
      divergences = described_class.divergences_for(race_step, %w[succeeded refused], ["succeeded", "crashed:RuntimeError: boom"])

      expect(divergences.size).to eq(1)
      expect(divergences.first[:field]).to eq("concurrency_crash")
      expect(divergences.first[:detail]).to eq("crashed:RuntimeError: boom")
    end
  end

  # File-based fixture: `IsolatedBoot.call`/`copy_dereferencing` need a real directory. Same
  # minimal shape as `EraConcurrencyGap` in `postgres_era_concurrent_dispatch_spec.rb`.
  context "with a real, disposable PostgresEra schema", :io do
    CONCURRENT_DISPATCH_SPEC_DATABASE = "hecks_concurrent_dispatch_spec".freeze

    # Namespaced: a constant assigned inside `RSpec.describe`/`context` lands on `Object`, so a
    # generic `FIXTURE_HECKSAGON` collides with other specs (`spec/load_hygiene_spec.rb`).
    CONCURRENT_DISPATCH_FIXTURE_BLUEBOOK = <<~RUBY.freeze
      Hecks.bluebook "ConcurrentDispatchFixture" do
        vision "The smallest domain that exercises a real cross-process write lock, authored only to prove Hecks::Fuzzing::ConcurrentDispatch works — never examples/, so this spec never depends on this repository's own live corpus staying any particular shape."
        supporting

        aggregate "Account" do
          identified_by :number

          attribute :number,  AccountNumber
          attribute :balance, Money, default: { cents: 0 }

          value_object "AccountNumber" do
            attribute :value, String
          end

          value_object "Money" do
            attribute :cents, Integer
            invariant("a balance is never negative") { cents >= 0 }
          end

          command "Open" do
            attribute :number,  AccountNumber
            attribute :balance, Money

            sets :number
            sets :balance

            emits "AccountOpened"
          end

          command "Debit" do
            reference_to Account
            attribute :amount, Money

            given("the balance covers it") { balance.cents >= amount.cents }

            sets :balance, decrement: :amount

            emits "AccountDebited"
          end
        end
      end
    RUBY

    CONCURRENT_DISPATCH_FIXTURE_HECKSAGON = <<~RUBY.freeze
      Hecks.hecksagon "ConcurrentDispatchFixture" do
        ConcurrentDispatchFixture::Account.persisted_by("PostgresEra")
      end
    RUBY

    before(:all) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      @fixture_root = Dir.mktmpdir("concurrent_dispatch_spec")
      File.write(File.join(@fixture_root, "fixture.bluebook"), CONCURRENT_DISPATCH_FIXTURE_BLUEBOOK)
      File.write(File.join(@fixture_root, "fixture.hecksagon"), CONCURRENT_DISPATCH_FIXTURE_HECKSAGON)

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{CONCURRENT_DISPATCH_SPEC_DATABASE} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{CONCURRENT_DISPATCH_SPEC_DATABASE}")
      admin.close
    end

    after(:all) do
      next unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{CONCURRENT_DISPATCH_SPEC_DATABASE} WITH (FORCE)")
      admin.close
      FileUtils.remove_entry(@fixture_root)
    end

    def open_step(number, cents)
      { "verb" => "ConcurrentDispatchFixture::Account.Open",
        "args" => { "number" => { "value" => number }, "balance" => { "cents" => cents } } }
    end

    def debit_step(number, cents)
      { "verb" => "ConcurrentDispatchFixture::Account.Debit",
        "args" => { "number" => { "value" => number }, "amount" => { "cents" => cents } } }
    end

    def check(steps, tag)
      described_class.check(@fixture_root, steps, database: CONCURRENT_DISPATCH_SPEC_DATABASE,
                                                    race_schema: "cd_race_#{tag}", reference_schema: "cd_ref_#{tag}")
    end

    # Two Debits that together overdraw the account: `Open` is setup, the middle command
    # is raced. A working lock serializes them as the oracle says, so no divergence.
    it "agrees with its own sequential oracle on a genuinely conflicting pair — the real lock holds" do
      steps = [open_step("a1", 10_000), debit_step("a1", 6_000), debit_step("a1", 6_000)]

      expect(check(steps, "conflict")).to eq([])
    end

    # Racing index 0: no setup step. Two concurrent `Open`s under one number collide on
    # identity; a working lock admits exactly one.
    it "agrees with its own sequential oracle when the race step is the sequence's own first step" do
      steps = [open_step("a2", 10_000)]

      expect(check(steps, "identity")).to eq([])
    end
  end

  # Regression: `attaches "X"` loads a framework member's shape but not its persistence,
  # so without a sibling `Hecks.hecksagon "X"` its aggregates default to Memory. Racing a
  # Memory-backed aggregate across two processes always diverges from the oracle (each process
  # has its own store), which is not a broken lock. This fixture reproduces that shape.
  context "with an aggregate attached via `attaches` but never given its own persistence binding", :io do
    CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE = "hecks_concurrent_dispatch_unbound_spec".freeze

    CONCURRENT_DISPATCH_UNBOUND_FIXTURE_BLUEBOOK = <<~RUBY.freeze
      Hecks.bluebook "ConcurrentDispatchUnboundFixture" do
        vision "A host domain that attaches Governance (attaches) but never gives it its own sibling hecksagon — the exact shape qa/bluebook/quality_control.hecksagon itself has today."
        supporting
      end
    RUBY

    CONCURRENT_DISPATCH_UNBOUND_FIXTURE_HECKSAGON = <<~RUBY.freeze
      Hecks.hecksagon "ConcurrentDispatchUnboundFixture" do
        attaches "Governance"
      end
    RUBY

    # Attaching Governance without this sibling refuses boot. Memory, not PostgresEra, so
    # RoleAssignment stays unshared across racers, which is the shape this example pins.
    CONCURRENT_DISPATCH_UNBOUND_CONTEXT_MAP = InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON

    before(:all) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      @unbound_fixture_root = Dir.mktmpdir("concurrent_dispatch_unbound_spec")
      File.write(File.join(@unbound_fixture_root, "fixture.bluebook"), CONCURRENT_DISPATCH_UNBOUND_FIXTURE_BLUEBOOK)
      File.write(File.join(@unbound_fixture_root, "fixture.hecksagon"), CONCURRENT_DISPATCH_UNBOUND_FIXTURE_HECKSAGON)
      File.write(File.join(@unbound_fixture_root, "context_map.hecksagon"), CONCURRENT_DISPATCH_UNBOUND_CONTEXT_MAP)

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE}")
      admin.close
    end

    after(:all) do
      next unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE} WITH (FORCE)")
      admin.close
      FileUtils.remove_entry(@unbound_fixture_root)
    end

    def assign_step(actor, role, scope, starts_at)
      { "verb" => "Governance::RoleAssignment.Assign",
        "args" => { "actor_id" => { "value" => actor }, "role_name" => { "value" => role },
                    "scope" => { "value" => scope }, "starts_at" => starts_at } }
    end

    # The oracle settles this pair as `["succeeded", "refused"]` (AlreadyExists within one
    # Memory store); raced across two processes it settles `["succeeded", "succeeded"]`
    # because each boots its own empty store. `check` should never pick this aggregate.
    it "reports a spurious concurrency_race today — racing an aggregate with no shared persistence guarantees one" do
      steps = [assign_step("golf", "Governance administrator", "bravo", "echo")]

      divergences = described_class.check(@unbound_fixture_root, steps,
                                          database: CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE,
                                          race_schema: "cd_race_unbound", reference_schema: "cd_ref_unbound")

      expect(divergences).to eq([]),
                             "expected no finding (Governance::RoleAssignment isn't durably, sharedly " \
                             "persisted in this fixture, so it should never have been raced at all) but " \
                             "got: #{divergences.inspect} — this is BUG#142, a false positive from racing " \
                             "a Memory-backed aggregate, not a broken PostgresEra write lock"
    end
  end
end
