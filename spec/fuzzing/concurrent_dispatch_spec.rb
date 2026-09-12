require "hecks/fuzzing/concurrent_dispatch"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"

# `Hecks::Fuzzing::ConcurrentDispatch`, PROVEN AGAINST THE SAME REAL
# CROSS-PROCESS LOCK `spec/adapters/driven/postgres_era_concurrent_
# dispatch_spec.rb` proves by hand — not a stand-in for it. That spec
# gates a hand-picked pair to force one exact interleaving deterministic
# enough to assert `%w[refused succeeded]` outright; this module has no
# such hand-authored knowledge of an arbitrary generated race, so its own
# design is to derive that expectation itself (the sequential oracle —
# see its own header) rather than assert a hardcoded shape. So this file
# proves TWO different things separately: the pure comparison logic
# (`divergences_for`, no Postgres needed at all), and the full real,
# forked, real-Postgres pipeline actually completing and agreeing with
# its own oracle on a genuinely conflicting pair — never a broken-lock
# case, the same reason the hand-authored spec has none either: nothing
# here deliberately reverts ADR 0036's own fix just to prove this module
# CAN fire; `divergences_for`'s own unit coverage proves that instead,
# with synthetic outcome pairs.
RSpec.describe Hecks::Fuzzing::ConcurrentDispatch do
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

  # A REAL, FILE-BASED FIXTURE — `IsolatedBoot.call`/`copy_dereferencing`
  # need a real directory on disk (never an in-memory registry the way
  # some other specs in this suite set state up), the same reason
  # `spec/fuzzing/persistence_parity_spec.rb`'s own fixture is files, not
  # `Kernel.eval`. The SAME minimal shape `postgres_era_concurrent_
  # dispatch_spec.rb`'s own `EraConcurrencyGap` fixture uses (one
  # numbered account, `Open`/`Debit`, a `given` balance check) —
  # deliberately reused rather than re-derived, since it is already the
  # smallest domain proven to exercise the real cross-process lock.
  context "with a real, disposable PostgresEra schema", :io do
    CONCURRENT_DISPATCH_SPEC_DATABASE = "hecks_concurrent_dispatch_spec".freeze

    # NAMESPACED, NOT THE GENERIC `FIXTURE_BLUEBOOK`/`FIXTURE_HECKSAGON`
    # OTHER SPEC FILES ALSO USE — `spec/qa_sweep_persistence_parity_spec.rb`'s
    # own comment on `spec/qa_sweep_all_spec.rb`'s `FIXTURE_HECKSAGON`
    # names the real gotcha this avoids: a bare `CONST = value` written
    # directly inside an `RSpec.describe`/`context do ... end` block
    # assigns at the block's own LEXICAL scope (top-level, i.e. `Object`),
    # never inside the dynamically-created example-group class, so two
    # spec files that both write the same generic name are defining the
    # SAME top-level constant — confirmed live: this file's own
    # `FIXTURE_HECKSAGON` collided with `spec/qa_sweep_all_spec.rb`'s own,
    # caught by `spec/load_hygiene_spec.rb`.
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

    # THE EXACT CLASS `postgres_era_concurrent_dispatch_spec.rb` PROVES BY
    # HAND, GENERALIZED — two Debits that together would overdraw the
    # account are the race step, generated-sequence-style: `Open` is
    # setup, the SECOND `Debit` (the sequence's own middle command) is
    # what gets raced. A working cross-process lock serializes them
    # exactly the way the sequential oracle says it must, so this is
    # clean — no divergence — and that agreement IS what is under test.
    it "agrees with its own sequential oracle on a genuinely conflicting pair — the real lock holds" do
      steps = [open_step("a1", 10_000), debit_step("a1", 6_000), debit_step("a1", 6_000)]

      expect(check(steps, "conflict")).to eq([])
    end

    # RACING INDEX 0 ITSELF — no setup step at all, the bare identity-
    # creation case `pick_race_index`'s own unit coverage names as
    # legitimate. Two concurrent `Open`s under the SAME number are a
    # genuine identity-collision race; a working lock still admits
    # exactly one, the same shape of agreement as the Debit case above.
    it "agrees with its own sequential oracle when the race step is the sequence's own first step" do
      steps = [open_step("a2", 10_000)]

      expect(check(steps, "identity")).to eq([])
    end
  end
end
