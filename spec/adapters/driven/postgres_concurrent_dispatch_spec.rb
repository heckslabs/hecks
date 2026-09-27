require "hecks"
require_relative "../../support/postgres_probe"

# Two independent Dispatchers (as in two processes) share one Postgres database and account row,
# and concurrently dispatch a `Debit` that each passes `given` alone but together overdraw it.
# Exactly one must be admitted; a state-dependent command's read (`hydrate_existing`) and its
# write (`save`) are not spanned by a lock, so the `given` can run against a stale snapshot.
#
# The fixture is minimal on purpose: Banking::Account hits an unrelated Postgres index-builder
# failure before any command dispatches, which would fail this spec for the wrong reason.
RSpec.describe "concurrent dispatch against one Postgres-backed aggregate", :io do
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

  # `Open` is state-independent; `Debit` reads `balance` in its `given` and `decrement`, so
  # `DependencyPlanning` chooses TRANSACTIONAL_FALLBACK (plain `find` + `save`), the path targeted.
  # Each `boot` builds a fresh Registry, as separate processes would; only the row is shared.
  #
  # The bluebook is one DSL block read top to bottom as the fixture; splitting it would scatter it.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
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

  # Forces both dispatches through `find` (`hydrate_existing`'s read) before either saves.
  # Only the first `find` per adapter pauses: a retry after `StaleWrite` re-reads the committed
  # balance and must run free, since `release` is handed out once per adapter.
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
    seed.dispatch_flat("ConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })

    # Each `boot` models a separate process: its own Registry, Dispatcher and `PG.connect`.
    first  = boot
    second = boot

    ready, release = synchronize_after_find(account_repository(first).adapter, account_repository(second).adapter)

    outcomes = Queue.new
    threads = [first, second].map do |dispatcher|
      Thread.new do
        dispatcher.dispatch_flat("ConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
        outcomes << :succeeded
      rescue Hecks::Runtime::GivenNotMet
        outcomes << :refused
      end
    end

    # Release both only once both have read, opening the lost-update window.
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    results = Array.new(2) { outcomes.pop }

    # A $10,000 account never honors two $6,000 debits: exactly one is admitted and the other
    # refused by "the balance covers it" against the committed balance.
    expect(results).to contain_exactly(:succeeded, :refused)

    verify = boot
    account = account_repository(verify).find("a")
    # The lost update: two debits are journaled but only one is reflected in the balance.
    expect(account[:balance].to_h[:cents]).to eq(4_000)
  end
end
