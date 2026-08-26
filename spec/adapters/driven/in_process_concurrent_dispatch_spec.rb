require "hecks"
require "tmpdir"

# THE HEKI/MEMORY COUSIN OF spec/adapters/driven/postgres_concurrent_dispatch_spec.rb
# — same fixture (an "Account" with a state-dependent `Debit`), same
# invariant (two concurrent $6,000 debits against a $10,000 balance must
# never both succeed), but modeling the shape THESE two adapters actually
# have: process-local data, no second process to model, so "concurrent" here
# means real `Thread`s inside ONE process sharing ONE `Registry` (and so the
# SAME adapter instance — `Registry#repository` memoizes), not two separate
# `boot`s the way the Postgres spec needs.
#
# Neither adapter declares `:optimistic_concurrency` — the mechanism under
# test here is `Runtime::AggregateLock`'s per-key `Mutex`
# (`CommandInterpreter#call`/`EntityInterpreter#call`'s own
# `run_dispatch_order_with_isolation`), not CAS+retry. A correctly-held
# lock means the second dispatch's own `hydrate` can never even START until
# the first dispatch's `save` has landed — so, unlike the Postgres spec,
# there is no window where both threads' `find` calls overlap; proving the
# lock works means proving that window CANNOT be forced open, not that a
# retry recovers from it.
RSpec.describe "concurrent dispatch against one process-local aggregate (Heki/Memory)" do
  def boot_for(adapter_name, dir: nil)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      # MEMORY, ALWAYS — same as postgres_concurrent_dispatch_spec.rb's own
      # `boot`: `registry.verify!` checks a usable DEFAULT adapter exists
      # regardless of which one this domain actually binds.
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/#{adapter_name.downcase}.adapter")) unless adapter_name == "Memory"
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("ConcurrencyGap") do
        vision "The smallest domain that reproduces a lost-update race for a state-dependent command, in one process."

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
        ConcurrencyGap::Account.persisted_by(adapter_name)
      end
      # Memory declares no settings fields at all (`memory.adapter`) — no
      # `Hecks.world` needed, same as `spec_helper.rb`'s own
      # `boot_in_memory`. Heki needs its own isolated tmpdir per example.
      if adapter_name == "Heki"
        Hecks.world("ConcurrencyGap") do
          persisted_by("Heki") { dir(dir) }
        end
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("ConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("ConcurrencyGap", aggregate)
  end

  # Marks the FIRST thread to reach `find` and pauses it briefly, giving a
  # concurrent dispatch a chance to also reach `find` before it resumes —
  # the exact race window a missing lock leaves open. BOUNDED, not a hang:
  # under a correctly serializing lock, no other thread can ever reach
  # `find` while the first holds it (the lock wraps the whole dispatch, not
  # just the read), so the wait simply times out and the first thread
  # proceeds having genuinely never overlapped with a second reader. A
  # second/later `find` call never waits at all — it just wakes whichever
  # first call is still pending and carries on.
  def install_race_window(adapter, timeout: 0.3)
    original_find = adapter.method(:find)
    arrived = Queue.new
    gate = Mutex.new
    signaled = false
    adapter.define_singleton_method(:find) do |id|
      result = original_find.call(id)
      first = gate.synchronize { !signaled && (signaled = true) }
      first ? arrived.pop(timeout: timeout) : (arrived << true)
      result
    end
  end

  shared_examples "serializes two concurrent Debits" do |adapter_name|
    it "admits exactly one of two concurrent Debits that together overdraw the account (#{adapter_name})" do
      dir = adapter_name == "Heki" ? Dir.mktmpdir("hecks-heki-concurrency-") : nil
      dispatcher = boot_for(adapter_name, dir: dir)
      dispatcher.dispatch("ConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })

      install_race_window(account_repository(dispatcher).adapter)

      outcomes = Queue.new
      threads = Array.new(2) do
        Thread.new do
          dispatcher.dispatch("ConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
          outcomes << :succeeded
        rescue Hecks::Runtime::GivenNotMet
          outcomes << :refused
        end
      end
      threads.each(&:join)

      results = Array.new(2) { outcomes.pop }

      # THE INVARIANT: a $10,000 account can never honor two $6,000
      # debits. The lock means the second dispatch's own `given` is
      # checked against the FIRST debit's already-committed balance, not
      # a stale snapshot — so it refuses for real, via `GivenNotMet`, not
      # merely "doesn't crash".
      expect(results).to contain_exactly(:succeeded, :refused)
      expect(account_repository(dispatcher).find("a")[:balance].to_h[:cents]).to eq(4_000)
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end

  it_behaves_like "serializes two concurrent Debits", "Heki"
  it_behaves_like "serializes two concurrent Debits", "Memory"
end
