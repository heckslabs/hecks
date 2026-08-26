require "hecks"
require_relative "../../support/postgres_probe"

# INVESTIGATION: docs/decisions/ (see the concurrency-model ADR/gap writeup
# committed alongside this spec) traced the dispatch pipeline
# (lib/hecks/runtime/command_interpreter.rb) and found no lock, transaction,
# or version check spanning the read (hydrate) and the write (save) for any
# command whose `given`/mutation reads prior aggregate state — which is
# exactly the TRANSACTIONAL_FALLBACK strategy `DependencyPlanning::Plan
# #strategy_for` chooses whenever a command is not state-independent
# (lib/hecks/runtime/dependency_planning.rb:26-31). `Postgres#atomic_put`
# takes a `pg_advisory_xact_lock` (lib/hecks/adapters/driven/postgres.rb:197-218),
# but `Postgres#save` — the path every state-dependent command actually
# takes — takes NO lock at all (postgres.rb:186-189), and the read that
# feeds the `given` check (`CommandInterpreter#hydrate_existing`,
# command_interpreter.rb:271-293, calling `Postgres#find`, postgres.rb:109-114)
# happens entirely before that write-side transaction even opens.
#
# A DELIBERATELY MINIMAL DOMAIN, not examples/banking — Banking::Account
# declares a real, unrelated Postgres adapter gap of its own (a cross-
# aggregate `where(:"customer/status" => ...)` query that
# postgres/schema_builder.rb's own index builder cannot translate, raising
# PG::UndefinedColumn before a single command ever dispatches). Reusing it
# here would make this spec fail for the wrong reason. This fixture
# isolates exactly the one mechanism under investigation: a `given` that
# reads prior aggregate state, on a command Postgres persists through the
# plain, lock-free `save` path.
#
# THIS SPEC DEMONSTRATES THE GAP, IT DOES NOT FIX IT. Two independent
# Dispatcher instances (the same shape two separate application processes
# take in production) both bound to the SAME Postgres database and the same
# "a" account row. Both concurrently dispatch `Debit` for an amount that
# individually satisfies `given("the balance covers it")` against the
# balance each one reads, but which together overdraw the account. A
# correct concurrency model admits exactly one of the two and refuses the
# other, because the second one's real balance (after the first's write)
# no longer covers it. Today, both are admitted — the second Debit's
# `given` is checked against a snapshot a concurrent writer is about to
# make stale, and the dispatcher never re-checks or locks anything in
# between.
RSpec.describe "concurrent dispatch against one Postgres-backed aggregate",
               io: true do
  DATABASE = "hecks_concurrency_gap_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{DATABASE}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DATABASE} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: DATABASE)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  # One aggregate, two commands: `Open` (state-independent — every field is
  # set from the payload, nothing read first) and `Debit` (state-dependent
  # — its own `given` reads `balance`, and `decrement` reads it again to
  # compute the new value). `Debit` is exactly the shape
  # DependencyPlanning::Analyzer marks NOT state_independent
  # (dependency_planning.rb:80-99), so `strategy_for` always falls back to
  # TRANSACTIONAL_FALLBACK (dependency_planning.rb:26-31) — the plain
  # `Postgres#find` + `Postgres#save` path this spec targets.
  #
  # A fresh Registry each `boot`, on purpose — two independent Dispatcher
  # instances is the same shape two separate application processes take in
  # production; the only thing they share is the Postgres row for account
  # "a".
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ADAPTER)

      Hecks.bluebook "ConcurrencyGap" do
        vision "The smallest domain that reproduces the dispatcher's own read-check-write gap for a state-dependent command."

        aggregate "Account" do
          description "One numbered account and its own balance in cents."

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
            goal "Start a fresh account with an opening balance"

            attribute :number,  AccountNumber
            attribute :balance, Money

            sets :number
            sets :balance

            emits "AccountOpened"
          end

          command "Debit" do
            goal "Take cents out of the account, if the balance covers it"

            reference_to Account
            attribute :amount, Money

            given("the balance covers it") { balance.cents >= amount.cents }

            sets :balance, decrement: :amount

            emits "AccountDebited"
          end
        end
      end

      Hecks.hecksagon("ConcurrencyGap") do
        ConcurrencyGap::Account.persisted_by("Postgres")
      end
      Hecks.world("ConcurrencyGap") do
        persisted_by("Postgres") { database(DATABASE) }
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("ConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("ConcurrencyGap", aggregate)
  end

  # Forces the exact interleaving CommandInterpreter's own pipeline never
  # guards against: both dispatches complete their `find` — the read half
  # of `hydrate_existing` — before EITHER reaches its own `save`. `find` is
  # not a fabricated seam; it is the one real method every state-dependent
  # dispatch already calls at exactly this point.
  #
  # ONLY THE FIRST `find` PER ADAPTER PAUSES. The fix under test retries a
  # losing dispatch's whole `#call` on `StaleWrite` (CommandInterpreter's
  # own optimistic-concurrency CAS) — a real, correct SECOND `find` inside
  # that retry, re-reading the FIRST debit's now-committed balance. That
  # second read must run free, not queue up waiting for a `release` token
  # this helper only ever hands out once per adapter; only the INITIAL
  # read is the one this test needs to force into the race window.
  def synchronize_after_find(*adapters)
    ready = Queue.new
    release = Queue.new
    adapters.each do |adapter|
      original_find = adapter.method(:find)
      gated_once = false
      adapter.define_singleton_method(:find) do |id|
        result = original_find.call(id)
        unless gated_once
          gated_once = true
          ready << true
          release.pop
        end
        result
      end
    end
    [ready, release]
  end

  it "admits two concurrent Debits that together overdraw the account, instead of refusing the second" do
    seed = boot
    seed.dispatch("ConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })

    # TWO SEPARATE PROCESSES, MODELED HONESTLY — each `boot` is its own
    # Registry, its own Dispatcher, its own real `PG.connect`.
    first  = boot
    second = boot

    ready, release = synchronize_after_find(account_repository(first).adapter, account_repository(second).adapter)

    outcomes = Queue.new
    threads = [first, second].map do |dispatcher|
      Thread.new do
        dispatcher.dispatch("ConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
        outcomes << :succeeded
      rescue Hecks::Runtime::GivenNotMet
        outcomes << :refused
      end
    end

    # Release both only once BOTH have read — the lost-update window this
    # gap leaves open.
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    results = Array.new(2) { outcomes.pop }

    # THE INVARIANT: a $10,000 account can never honor two $6,000 debits.
    # Correctly serialized, exactly one of these two concurrent Debits is
    # admitted and the other is refused by "the balance covers it" —
    # re-checked against the FIRST debit's committed balance, not the
    # stale snapshot both actually read. This is the assertion that fails
    # today: both are admitted.
    expect(results).to contain_exactly(:succeeded, :refused)

    verify = boot
    account = account_repository(verify).find("a")
    # A second symptom of the same gap: the persisted balance (whichever
    # writer's `save` committed last) does not equal the sum the ledger's
    # own append-only entries claim was taken out. Two $6,000 debits are
    # both journaled, but only one $6,000 debit is reflected in the
    # $10,000 - $6,000 = $4,000 balance below — the other's effect on the
    # account was silently lost, not refused.
    expect(account[:balance].to_h[:cents]).to eq(4_000)
  end
end
