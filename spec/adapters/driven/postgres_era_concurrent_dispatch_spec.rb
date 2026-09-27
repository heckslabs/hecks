require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"

# Two forked processes dispatching against one PostgresEra aggregate are serialized by its
# cross-process advisory lock (ADR 0036). Forks, not threads: threads share `AggregateLock`.
RSpec.describe "concurrent dispatch against one PostgresEra-backed aggregate", :io do
  ERA_CONCURRENCY_DATABASE = "hecks_postgres_era_concurrency_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{ERA_CONCURRENCY_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{ERA_CONCURRENCY_DATABASE}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{ERA_CONCURRENCY_DATABASE} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: ERA_CONCURRENCY_DATABASE)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  # Same Account fixture as postgres_concurrent_dispatch_spec.rb, bound to PostgresEra.
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
        persisted_by("PostgresEra") { database(ERA_CONCURRENCY_DATABASE) }
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("EraConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("EraConcurrencyGap", aggregate)
  end

  # Pauses the adapter's first `lock_writes!` call once it holds the advisory lock. Only the
  # first call is gated because `append` re-takes the lock inside its own transaction.
  # Callbacks are relayed over pipes, since an in-process Queue does not cross a fork.
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

  # One forked racer: boots its own Dispatcher, gates its first `lock_writes!` per `gate_opts`,
  # dispatches the shared Debit, and writes "label:outcome" to `outcome_write`.
  def fork_debit_racer(label, outcome_write, close:, **gate_opts)
    fork do
      close.each(&:close)
      dispatcher = boot
      gate_first_lock(account_repository(dispatcher).adapter, **gate_opts)
      outcome =
        begin
          dispatcher.dispatch_flat("EraConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
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
    seed.dispatch_flat("EraConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })

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

    # Fork the second racer only once the first holds the lock, or arrival order is a race.
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

    # Resume the first racer while the second waits on the lock: exactly one may be admitted,
    # the other refused against the committed balance.
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
    # A $10,000 account cannot honor two $6,000 debits; a lost update would persist only one.
    expect(account[:balance].to_h[:cents]).to eq(4_000)
  end
end
