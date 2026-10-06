require "hecks"
require_relative "../../support/postgres_probe"
require_relative "../../support/concurrency_gap_domain"

# Two independent Dispatchers (as in two processes) share one Postgres database and account row,
# and concurrently dispatch a `Debit` that each passes `given` alone but together overdraw it.
# Exactly one must be admitted; a state-dependent command's read (`hydrate_existing`) and its
# write (`save`) are not spanned by a lock, so the `given` can run against a stale snapshot.
#
# The fixture is minimal on purpose: Banking::Account hits an unrelated Postgres index-builder
# failure before any command dispatches, which would fail this spec for the wrong reason.
RSpec.describe "concurrent dispatch against one Postgres-backed aggregate", :io do
  DATABASE = "hecks_concurrency_gap_spec".freeze
  POSTGRES_GAP_VISION =
    "The smallest domain that reproduces the dispatcher's own read-check-write gap for a state-dependent command.".freeze

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
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_ports
      ConcurrencyGapDomain.declare("ConcurrencyGap", vision: POSTGRES_GAP_VISION)
      Hecks.hecksagon("ConcurrencyGap") { ConcurrencyGap::Account.persisted_by("Postgres") }
      Hecks.world("ConcurrencyGap") { persisted_by("Postgres") { database(DATABASE) } }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def load_ports
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(InMemoryDomain::POSTGRES_ADAPTER)
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
    adapters.each { |adapter| gate_first_find(adapter, ready, release) }
    [ready, release]
  end

  def gate_first_find(adapter, ready, release)
    original_find = adapter.method(:find)
    gated_once = false
    adapter.define_singleton_method(:find) do |id|
      original_find.call(id).tap do
        next if gated_once

        gated_once = true
        ready << true
        release.pop
      end
    end
  end

  def debit_in_thread(dispatcher, outcomes)
    Thread.new do
      dispatcher.dispatch_flat("ConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
      outcomes << :succeeded
    rescue Hecks::Runtime::GivenNotMet
      outcomes << :refused
    end
  end

  # Dispatches the same Debit from both dispatchers, each paused after its read, and answers
  # how each ended.
  def race_gated_debits(first, second)
    ready, release = synchronize_after_find(account_repository(first).adapter, account_repository(second).adapter)
    outcomes = Queue.new
    threads = [first, second].map { |dispatcher| debit_in_thread(dispatcher, outcomes) }

    # Release both only once both have read, opening the lost-update window.
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)
    Array.new(2) { outcomes.pop }
  end

  let(:results) do
    boot.dispatch_flat("ConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })
    # Each `boot` models a separate process: its own Registry, Dispatcher and `PG.connect`.
    race_gated_debits(boot, boot)
  end

  # A $10,000 account never honors two $6,000 debits: exactly one is admitted and the other
  # refused by "the balance covers it" against the committed balance. A lost update would
  # journal two debits but reflect only one in the balance.
  it "admits two concurrent Debits that together overdraw the account, instead of refusing the second",
     :aggregate_failures do
    expect(results).to contain_exactly(:succeeded, :refused)
    expect(account_repository(boot).find("a")[:balance].to_h[:cents]).to eq(4_000)
  end
end
