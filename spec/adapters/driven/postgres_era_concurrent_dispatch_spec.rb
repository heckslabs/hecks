require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"

# ADR 0036's OWN FIX, PROVEN LIVE. `postgres_concurrent_dispatch_spec.rb`
# (this same directory) demonstrates the analogous gap for plain
# `Postgres` and is deliberately left unfixed there (CAS/retry is a
# separate, larger design). For `PostgresEra`, ADR 0036 traced the gap
# to `run_dispatch_order_with_isolation` (runtime/interpreting.rb): a
# repository not advertising `:optimistic_concurrency` falls back to
# `Runtime::AggregateLock`, an IN-PROCESS Ruby `Mutex` — correct for
# Heki/Memory (confirmed process-local), invisible the moment
# `rust/host` dispatches against the same `PostgresEra`-bound tables
# from a separate OS process. The fix: `PostgresEra` now advertises
# `:cross_process_lock` and exposes `with_write_lock`, which holds a
# REAL `pg_advisory_xact_lock` for the whole dispatch order (hydrate
# through save), not just around the final write.
#
# WHY REAL `Process.fork`, NOT `Thread.new` (unlike
# postgres_concurrent_dispatch_spec.rb's own plain-Postgres version) —
# `Runtime::AggregateLock` is a PROCESS-WIDE registry (aggregate_lock.rb's
# own header: "two `Runtime.boot` calls get two entirely separate adapter
# instances... only possibly other THREADS within this one process").
# Two threads in one process already share that same in-process registry
# and would be fully — and misleadingly — serialized by it even WITHOUT
# this fix: confirmed directly while building this spec, the identical
# scenario run as two Threads instead of two forked processes deadlocks
# the instant the fix is reverted, because the second racer never even
# reaches `PostgresEra#lock_writes!` (blocked earlier, on the in-process
# Mutex, which two threads DO share). Only two real, separate OS
# processes — each with its own empty `AggregateLock` registry, the
# exact shape a Ruby process and `rust/host` take in production — can
# actually exercise the cross-process gap this fix closes.
RSpec.describe "concurrent dispatch against one PostgresEra-backed aggregate", :io do
  DATABASE = "hecks_postgres_era_concurrency_spec".freeze

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

  # Same minimal fixture shape as postgres_concurrent_dispatch_spec.rb's
  # own Account, bound to PostgresEra instead of plain Postgres.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)

      Hecks.bluebook "EraConcurrencyGap" do
        vision "The smallest domain that exercises PostgresEra's cross-process write lock."

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

      Hecks.hecksagon("EraConcurrencyGap") do
        EraConcurrencyGap::Account.persisted_by("PostgresEra")
      end
      Hecks.world("EraConcurrencyGap") do
        persisted_by("PostgresEra") { database(DATABASE) }
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("EraConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("EraConcurrencyGap", aggregate)
  end

  # Gates the FIRST caller of the adapter's own private `lock_writes!`
  # (reachable via `define_singleton_method` despite the visibility),
  # pausing it once it genuinely holds the real advisory lock.
  # `gated_once` matters here specifically because `with_write_lock`
  # takes this same lock once for the whole dispatch, and `append`
  # harmlessly re-takes it once more inside its own transaction (see
  # `postgres_era.rb`'s own comment) — only the FIRST call is the one
  # under test. `on_entry`/`on_paused` fire synchronously, in-process,
  # so a forked caller can relay them across a real pipe back to the
  # parent (an in-process Queue does not cross a fork boundary).
  def gate_first_lock(adapter, on_entry:, on_paused:, wait_for_resume:)
    gated_once = false
    original = adapter.method(:lock_writes!)
    adapter.define_singleton_method(:lock_writes!) do
      on_entry.call unless gated_once
      result = original.call
      unless gated_once
        gated_once = true
        on_paused.call
        wait_for_resume.call
      end
      result
    end
  end

  # One forked racer: boots its own Dispatcher (its own real PG
  # connection, its own empty AggregateLock registry — see the file
  # header), gates its FIRST `lock_writes!` call per `gate_opts`,
  # dispatches the same Debit every racer dispatches, and reports which
  # outcome it got back down `outcome_write` labeled by `label`.
  def fork_debit_racer(label, outcome_write, close:, **gate_opts)
    fork do
      close.each(&:close)
      dispatcher = boot
      gate_first_lock(account_repository(dispatcher).adapter, **gate_opts)
      outcome =
        begin
          dispatcher.dispatch("EraConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
          "succeeded"
        rescue Hecks::Runtime::GivenNotMet
          "refused"
        end
      outcome_write.write("#{label}:#{outcome}\n")
      outcome_write.close
    end
  end

  # rubocop:disable-next RSpec/ExampleLength
  it "admits exactly one of two concurrent cross-process Debits that together would overdraw the account" do
    seed = boot
    seed.dispatch("EraConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })

    outcome_read,  outcome_write  = IO.pipe
    paused_read,   paused_write   = IO.pipe
    entered_read,  entered_write  = IO.pipe
    resume_read,   resume_write   = IO.pipe

    first_pid = fork_debit_racer(
      "first", outcome_write,
      close:           [outcome_read, paused_read, entered_read, entered_write, resume_write],
      on_entry:        -> {},
      on_paused:       lambda {
        paused_write.write("1")
        paused_write.close
      },
      wait_for_resume: -> { resume_read.read(1) }
    )

    # Don't fork the second racer until the first genuinely holds the
    # real lock — otherwise which racer reaches `lock_writes!` first is
    # a startup-order race the test cannot control, and the "blocked"
    # assertion below would sometimes observe nothing worth proving.
    raise "first process never signalled paused" unless paused_read.wait_readable(10)

    paused_read.read(1)

    second_pid = fork_debit_racer(
      "second", outcome_write,
      close:           [outcome_read, paused_write, resume_read, resume_write],
      on_entry:        -> { entered_write.write("1") },
      on_paused:       -> {},
      wait_for_resume: -> {}
    )

    [paused_write, entered_write, resume_read, outcome_write].each(&:close)

    raise "second process never even entered lock_writes!" unless entered_read.wait_readable(10)

    # THE ASSERTION THIS SPEC EXISTS FOR: resume the first racer now,
    # letting it finish its whole dispatch (hydrate through commit)
    # while the second is already past `lock_writes!`. Before ADR
    # 0036's fix, `PostgresEra` fell back to `Runtime::AggregateLock`,
    # an in-process `Mutex` invisible to this second, separate OS
    # process — both racers would have hydrated unlocked and raced for
    # the write, and this assertion is what catches that: exactly one
    # of the two real processes is admitted, the other correctly
    # refused against the first's now-committed balance.
    resume_write.write("go")
    resume_write.close

    Process.wait(first_pid)
    Process.wait(second_pid)

    results = {}
    2.times do
      who, what = outcome_read.readline.chomp.split(":")
      results[who] = what
    end

    expect(results.values.sort).to eq(%w[refused succeeded])

    verify = boot
    account = account_repository(verify).find("a")
    # THE SECOND SYMPTOM: a $10,000 account can never honor two $6,000
    # debits. Without real cross-process serialization, the persisted
    # balance would reflect only whichever commit landed last, while
    # BOTH debits were journaled as succeeded — the exact corruption
    # postgres_concurrent_dispatch_spec.rb documents for plain Postgres.
    expect(account[:balance].to_h[:cents]).to eq(4_000)
  end
end
