# frozen_string_literal: true

require "spec_helper"

# THE RULES A COMMAND OBEYS WHATEVER IT ACTS ON, pinned from BOTH paths.
#
# A record and one element inside it are different subjects, and for a while
# they were served by different code : EntityInterpreter carried its own copy
# of the Integer-or-nothing rule, error strings and all, with a comment saying
# so. Two copies of a money-safety invariant is how a ledger drifts — and the
# parity harness compares refusal WORDING, so tightening one message and not
# the other only surfaces if the corpus happens to drive both paths. It did
# not : until `LedgerEntry.Amend` existed, no element arithmetic ran anywhere
# in the corpus, in either runtime.
#
# So these examples drive the SAME rule from both sides and assert the SAME
# words. That is the contract the Rust projection answers to : its
# `mutations.rs::arithmetic` is called by both its record path and its element
# path, and these strings are what both must produce.
#
# Pinned against the REAL banking bluebook, loaded WITHOUT its hecksagon, so
# every aggregate takes the Memory default and the spec does no IO.
RSpec.describe "the rules a command obeys" do
  RULES_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")
  RULES_TILL    = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  # The RECORD path is driven by the till rather than by banking, because
  # banking's Credit guards `amount.positive?` FIRST — a non-Integer there
  # never reaches the arithmetic, it dies in the given. The till counts with
  # nothing in the way, which is what it was written for.
  def boot(bluebook)
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(bluebook)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def boot_banking = boot(RULES_BANKING)
  def boot_till    = boot(RULES_TILL)

  # acct-1 with one posted entry (sequence 1) of 10_000.
  def funded_account(runtime)
    runtime.dispatch("Banking::Account.Open", id: "a1", customer: "c", number: "ACC-1",
                                              kind: "current", daily_limit: 50_000)
    runtime.dispatch("Banking::Account.Credit", id: "a1", amount: 10_000, narrative: "Opening")
    runtime
  end

  def narrative = { text: "Corrected" }

  describe "Integer-or-nothing arithmetic" do
    it "refuses a non-Integer amount on a RECORD, in so many words" do
      runtime = boot_till
      runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")

      expect do
        runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: "a lot")
      end.to raise_error(Hecksagain::Runtime::TypeMismatch,
                         'increment of balance needs an Integer, got "a lot"')
    end

    it "refuses a non-Integer amount on an ELEMENT, in the same words" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         id: "a1", sequence: 1, adjustment: "a lot", narrative: narrative)
      end.to raise_error(Hecksagain::Runtime::TypeMismatch,
                         'increment of amount needs an Integer, got "a lot"')
    end

    it "moves an element by exactly what it was told" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                       id: "a1", sequence: 1, adjustment: 500, narrative: narrative)

      entry = runtime.query("Banking::Account.LedgerEntry.Reversed")
      expect(entry).to be_empty # amending does not reverse

      state = runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                               id: "a1", sequence: 1, adjustment: -200, narrative: narrative)
                     .state
      # 10_000 credited, +500 amended, -200 amended again — arithmetic all the
      # way down, and never a coerced word.
      expect(state[:ledger].first[:amount]).to eq(10_300)
    end

    it "decrements an element by the same rule, not a sign it invented" do
      runtime = funded_account(boot_banking)
      state   = runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                                 id: "a1", sequence: 1, adjustment: -1_000, narrative: narrative)
                       .state

      expect(state[:ledger].first[:amount]).to eq(9_000)
    end
  end

  describe "the state machine" do
    it "refuses a move an AGGREGATE's machine does not admit" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.Freeze", id: "a1")

      expect do
        runtime.dispatch("Banking::Account.Freeze", id: "a1")
      end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                         'Freeze refused — status is "frozen", and Freeze moves it only from "open"')
    end

    it "refuses a move an ENTITY's own machine does not admit, in the same shape" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       id: "a1", sequence: 1, narrative: narrative)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         id: "a1", sequence: 1, adjustment: 100, narrative: narrative)
      end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                         'Amend refused — state is "reversed", and Amend moves it only from "posted"')
    end
  end

  describe "the rules have one home" do
    # The seam this spec exists to defend. An interpreter that publishes its
    # internal steps so another can call them is not a peer — it is a room with
    # its guts on the outside, and the next caller reaches for a different four.
    it "leaves each interpreter with one verb" do
      surface = lambda do |klass|
        klass.public_instance_methods(false).sort - [:registry]
      end

      expect(surface[Hecksagain::Runtime::CommandInterpreter]).to eq([:call])
      expect(surface[Hecksagain::Runtime::EntityInterpreter]).to  eq([:call])
      expect(surface[Hecksagain::Runtime::QueryInterpreter]).to   eq([:call])
      expect(surface[Hecksagain::Runtime::PolicyInterpreter]).to  eq([:react])
      expect(surface[Hecksagain::Runtime::SagaInterpreter]).to    eq([:advance])
    end
  end
end
