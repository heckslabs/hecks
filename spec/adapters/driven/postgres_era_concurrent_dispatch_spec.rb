require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"
require_relative "../../support/concurrency_gap_domain"

# Two forked processes dispatching against one PostgresEra aggregate are serialized by its
# cross-process advisory lock (ADR 0036). Forks, not threads: threads share `AggregateLock`.
RSpec.describe "concurrent dispatch against one PostgresEra-backed aggregate", :io do
  ERA_CONCURRENCY_DATABASE = "hecks_postgres_era_concurrency_spec".freeze
  ERA_GAP_VISION = "The smallest domain that exercises PostgresEra's cross-process write lock.".freeze

  # The four pipes the racers and the example talk over, as read and write ends: callbacks
  # are relayed over pipes, since an in-process Queue does not cross a fork.
  EraRacePipes = Struct.new(:outcome_read, :outcome_write, :paused_read, :paused_write,
                            :entered_read, :entered_write, :resume_read, :resume_write) do
    def self.open = new(*Array.new(4) { IO.pipe }.flatten)
  end

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
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_ports
      ConcurrencyGapDomain.declare("EraConcurrencyGap", vision: ERA_GAP_VISION)
      Hecks.hecksagon("EraConcurrencyGap") { EraConcurrencyGap::Account.persisted_by("PostgresEra") }
      Hecks.world("EraConcurrencyGap") { persisted_by("PostgresEra") { database(ERA_CONCURRENCY_DATABASE) } }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def load_ports
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("EraConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("EraConcurrencyGap", aggregate)
  end

  # Pauses the adapter's first `lock_writes!` call once it holds the advisory lock, running
  # `on_pause` there. Only the first call is gated because `append` re-takes the lock inside
  # its own transaction.
  def gate_first_lock(adapter, on_entry:, on_pause:)
    gated_once = false
    original = adapter.method(:lock_writes!)
    adapter.define_singleton_method(:lock_writes!) do
      on_entry.call unless gated_once
      result = original.call
      return result if gated_once

      gated_once = true
      on_pause.call
      result
    end
  end

  def debit_outcome(dispatcher)
    dispatcher.dispatch_flat("EraConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
    "succeeded"
  rescue Hecks::Runtime::GivenNotMet
    "refused"
  end

  # One forked racer: boots its own Dispatcher, gates its first `lock_writes!` per `gate_opts`,
  # dispatches the shared Debit, and writes "label:outcome" to `outcome_write`.
  def fork_debit_racer(label, outcome_write, close:, **gate_opts)
    fork do
      close.each(&:close)
      dispatcher = boot
      gate_first_lock(account_repository(dispatcher).adapter, **gate_opts)
      outcome_write.write("#{label}:#{debit_outcome(dispatcher)}\n")
      outcome_write.close
    end
  end

  # Tells the example the first racer holds the lock, then waits to be told to go on.
  def pause_first_racer(pipes)
    pipes.paused_write.write("1")
    pipes.paused_write.close
    pipes.resume_read.read(1)
  end

  def fork_first_racer(pipes)
    fork_debit_racer(
      "first", pipes.outcome_write,
      close:    [pipes.outcome_read, pipes.paused_read, pipes.entered_read, pipes.entered_write, pipes.resume_write],
      on_entry: -> {},
      on_pause: -> { pause_first_racer(pipes) }
    )
  end

  def fork_second_racer(pipes)
    fork_debit_racer(
      "second", pipes.outcome_write,
      close:    [pipes.outcome_read, pipes.paused_write, pipes.resume_read, pipes.resume_write],
      on_entry: -> { pipes.entered_write.write("1") },
      on_pause: -> {}
    )
  end

  # Forks the first racer, and the second only once the first holds the lock (or arrival order
  # is a race), then drops the parent's copies of the ends only the racers use.
  def start_racers(pipes)
    first_pid = fork_first_racer(pipes)
    await_readable(pipes.paused_read, "first process never signalled paused")
    pipes.paused_read.read(1)
    second_pid = fork_second_racer(pipes)
    [pipes.paused_write, pipes.entered_write, pipes.resume_read, pipes.outcome_write].each(&:close)
    [first_pid, second_pid]
  end

  def await_readable(io, message)
    raise message unless io.wait_readable(10)
  end

  # Resumes the first racer while the second waits on the lock, and answers `{ label => outcome }`.
  def finish_race(pipes, pids)
    await_readable(pipes.entered_read, "second process never even entered lock_writes!")
    pipes.resume_write.write("go")
    pipes.resume_write.close
    pids.each { |pid| Process.wait(pid) }
    Array.new(2) { pipes.outcome_read.readline.chomp.split(":") }.to_h
  end

  let(:results) do
    boot.dispatch_flat("EraConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })
    pipes = EraRacePipes.open
    finish_race(pipes, start_racers(pipes))
  end

  # Exactly one may be admitted, the other refused against the committed balance: a $10,000
  # account cannot honor two $6,000 debits, and a lost update would persist only one.
  it "admits exactly one of two concurrent cross-process Debits that together would overdraw the account",
     :aggregate_failures do
    expect(results.values.sort).to eq(%w[refused succeeded])
    expect(account_repository(boot).find("a")[:balance].to_h[:cents]).to eq(4_000)
  end
end
