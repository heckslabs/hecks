require "hecks/fuzzing/concurrent_dispatch"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"

# `Hecks::Fuzzing::ConcurrentDispatch`, proven against the same real
# cross-process lock `spec/adapters/driven/postgres_era_concurrent_
# dispatch_spec.rb` proves by hand — not a stand-in for it. That spec
# gates a hand-picked pair to force one exact interleaving deterministic
# enough to assert `%w[refused succeeded]` outright; this module has no
# such hand-authored knowledge of an arbitrary generated race, so its own
# design is to derive that expectation itself (the sequential oracle —
# see its own header) rather than assert a hardcoded shape. So this file
# proves two different things separately: the pure comparison logic
# (`divergences_for`, no Postgres needed at all), and the full real,
# forked, real-Postgres pipeline actually completing and agreeing with
# its own oracle on a genuinely conflicting pair — never a broken-lock
# case, the same reason the hand-authored spec has none either: nothing
# here deliberately reverts ADR 0036's own fix just to prove this module
# can fire; `divergences_for`'s own unit coverage proves that instead,
# with synthetic outcome pairs.
RSpec.describe Hecks::Fuzzing::ConcurrentDispatch do
  # **A probe that broke is not a sequence with nothing to race**. Both used
  # to answer `[]`, which `bin/qa_sweep` logs as a clean concurrency
  # Check — so a renamed capability symbol or a wiring change could make
  # the race silently never happen while the ledger recorded the mode as
  # held. No Postgres here: the refusal happens before any boot.
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

  # **A real, file-based fixture** — `IsolatedBoot.call`/`copy_dereferencing`
  # need a real directory on disk (never an in-memory registry the way
  # some other specs in this suite set state up), the same reason
  # `spec/fuzzing/persistence_parity_spec.rb`'s own fixture is files, not
  # `Kernel.eval`. The same minimal shape `postgres_era_concurrent_
  # dispatch_spec.rb`'s own `EraConcurrencyGap` fixture uses (one
  # numbered account, `Open`/`Debit`, a `given` balance check) —
  # deliberately reused rather than re-derived, since it is already the
  # smallest domain proven to exercise the real cross-process lock.
  context "with a real, disposable PostgresEra schema", :io do
    CONCURRENT_DISPATCH_SPEC_DATABASE = "hecks_concurrent_dispatch_spec".freeze

    # Namespaced, not the generic `FIXTURE_BLUEBOOK`/`FIXTURE_HECKSAGON`
    # other spec files also use — `spec/qa_sweep_persistence_parity_spec.rb`'s
    # own comment on `spec/support/qa_sweep_all_fixture.rb`'s `FIXTURE_HECKSAGON`
    # names the real gotcha this avoids: a bare `CONST = value` written
    # directly inside an `RSpec.describe`/`context do ... end` block
    # assigns at the block's own lexical scope (top-level, i.e. `Object`),
    # never inside the dynamically-created example-group class, so two
    # spec files that both write the same generic name are defining the
    # same top-level constant — confirmed live: this file's own
    # `FIXTURE_HECKSAGON` collided with `spec/support/qa_sweep_all_fixture.rb`'s own,
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

    # The exact class `postgres_era_concurrent_dispatch_spec.rb` proves by
    # hand, generalized — two Debits that together would overdraw the
    # account are the race step, generated-sequence-style: `Open` is
    # setup, the second `Debit` (the sequence's own middle command) is
    # what gets raced. A working cross-process lock serializes them
    # exactly the way the sequential oracle says it must, so this is
    # clean — no divergence — and that agreement is what is under test.
    it "agrees with its own sequential oracle on a genuinely conflicting pair — the real lock holds" do
      steps = [open_step("a1", 10_000), debit_step("a1", 6_000), debit_step("a1", 6_000)]

      expect(check(steps, "conflict")).to eq([])
    end

    # **Racing index 0 itself** — no setup step at all, the bare identity-
    # creation case `pick_race_index`'s own unit coverage names as
    # legitimate. Two concurrent `Open`s under the same number are a
    # genuine identity-collision race; a working lock still admits
    # exactly one, the same shape of agreement as the Debit case above.
    it "agrees with its own sequential oracle when the race step is the sequence's own first step" do
      steps = [open_step("a2", 10_000)]

      expect(check(steps, "identity")).to eq([])
    end
  end

  # BUG#142 — found by the first real sweep of the `concurrency` mode
  # (SW-quality_control-1789768606, seed 3, race step
  # `Governance::RoleAssignment.Assign`). `check` picked a race step
  # whose aggregate isn't actually bound to anything shared across
  # processes: `uses_framework "X"` only loads a framework member's
  # shape (`hecksagon_builder.rb`'s own `uses_framework`), never its
  # persistence — see `examples/banking/bluebook/banking.hecksagon`'s
  # own comment on why a sibling `Hecks.hecksagon "X"` is required to
  # bind a framework member's own aggregates to anything but the
  # default (`Ports::Persistence::BindingPolicy.default_binding` —
  # `"Memory"`, silently, when no hecksagon is registered under that
  # name at all: `resolve` only raises `missing_binding` when a
  # hecksagon exists for that domain and simply omits this aggregate).
  # `qa/bluebook/quality_control.hecksagon` attaches `Governance` via
  # `uses_framework` and never gives it that sibling hecksagon, so
  # `Governance::RoleAssignment`/`RoleTransition` are Memory-backed —
  # process-local — in the real ledger too, `concurrency` mode included.
  # Racing a Memory-backed aggregate across two real OS processes is
  # certain to "diverge" from the single-process sequential oracle: each
  # racer's own boot gets its own empty Memory store, so a `creates?`
  # command's own identity collision can never be seen by the other
  # racer — not a broken lock, nothing to lock at all. This fixture
  # reproduces the exact shape (a host domain attaching a framework
  # member with no sibling hecksagon) without depending on qa/bluebook's
  # own corpus staying any particular shape.
  context "with an aggregate attached via uses_framework but never given its own persistence binding", :io do
    CONCURRENT_DISPATCH_UNBOUND_SPEC_DATABASE = "hecks_concurrent_dispatch_unbound_spec".freeze

    CONCURRENT_DISPATCH_UNBOUND_FIXTURE_BLUEBOOK = <<~RUBY.freeze
      Hecks.bluebook "ConcurrentDispatchUnboundFixture" do
        vision "A host domain that attaches Governance (uses_framework) but never gives it its own sibling hecksagon — the exact shape qa/bluebook/quality_control.hecksagon itself has today."
        supporting
      end
    RUBY

    CONCURRENT_DISPATCH_UNBOUND_FIXTURE_HECKSAGON = <<~RUBY.freeze
      Hecks.hecksagon "ConcurrentDispatchUnboundFixture" do
        uses_framework "Governance"
      end
    RUBY

    before(:all) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      @unbound_fixture_root = Dir.mktmpdir("concurrent_dispatch_unbound_spec")
      File.write(File.join(@unbound_fixture_root, "fixture.bluebook"), CONCURRENT_DISPATCH_UNBOUND_FIXTURE_BLUEBOOK)
      File.write(File.join(@unbound_fixture_root, "fixture.hecksagon"), CONCURRENT_DISPATCH_UNBOUND_FIXTURE_HECKSAGON)

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

    # **The false positive itself** — the identical pair, dispatched
    # sequentially with no contention (the oracle), correctly settles as
    # `["succeeded", "refused"]`: a `creates?` command's second dispatch
    # under the same identity is a genuine `AlreadyExists`, and that
    # works fine within one process's own Memory store. The "concurrent"
    # pair, raced across two real OS processes, settles as
    # `["succeeded", "succeeded"]` — not because any write lock failed
    # to serialize them, but because each racer process boots its own
    # independent, empty Memory-backed `RoleAssignment` store that never
    # shares anything with the other. `check` reports this as a
    # `concurrency_race` today; it should never have picked this
    # aggregate as a race candidate at all.
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
