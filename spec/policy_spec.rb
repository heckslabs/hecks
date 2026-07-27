# frozen_string_literal: true

require "spec_helper"

# THE DOMAIN'S REFLEX, finally connected.
#
# Four policies across the corpus — pizzas' NotifyOnPurchase, banking's
# ReviewOnFreeze / FreezeAccountsOnSuspension / NotifyOnClosure — parsed, reached
# the IR, and were agreed on byte-for-byte by both parsers. Then both runtimes
# dropped them. Parity was green BECAUSE both discarded them equally : stage one
# cannot tell "both understood it" from "both threw it away", and stage two
# cannot see an effect nobody produces.
#
# IR::Policy even carried `event_qualifier` and `event_name` — matching helpers
# written for a reaction that was never wired, and never called by anything.
RSpec.describe "a policy" do
  REFLEX_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/reflex.bluebook")

  # The fixture stays a real FILE for the reason spec_helper gives : Prism reads
  # a predicate's source, so a bluebook eval'd from a string has no source and
  # every `given` comes back empty.
  def boot_reflex
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(REFLEX_BLUEBOOK)
      # bind_runtime is what teaches the generated classes which runtime they
      # belong to — Loader.boot does it, and a spec composing a registry by hand
      # has to as well or `Light.find` has no runtime to ask.
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  # Purchase is guarded : a pizza needs at least one topping before it sells.
  def topped_pizza(runtime)
    pizza = runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", price_cents: 900)
    runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Basil", amount: 3)
    pizza
  end

  it "fires the command its event names, and the reaction lands" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Light.Flip", id: "light-1")

    # Flip set "on" ; the reaction ran Log, which set "logged". Reading the
    # state back is what proves the second command actually executed rather
    # than merely being recorded as attempted.
    expect(Reflex::Light.find("light-1").condition).to eq("logged")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped",
                     trigger: "Reflex::Light.Log", delivered: true)
    )
  end

  it "fires once per matching event, not once per declaration site" do
    # An aggregate-nested policy BUBBLES to the domain at build time and the
    # aggregate keeps its own copy, so reading both lists fired every nested
    # policy twice — four reactions for two events. bluebook_builder says where
    # the two agree : "the interpreter holds them domain-level only".
    runtime = boot_reflex
    runtime.dispatch("Reflex::Light.Flip", id: "light-1")
    runtime.dispatch("Reflex::Light.Flip", id: "light-2")

    expect(runtime.reactions.size).to eq(2)
  end

  # THE GUARD, EXERCISED. Echo.Ring emits Rang and RingOnRang answers Rang by
  # ringing again. Without a bound this recurses until the stack gives out ; the
  # bound is what turns a modelling error into a recorded refusal.
  #
  # Written because the guard existed and nothing reached it — the same shape as
  # every bug found today : legal, unexercised, unverified.
  it "stops a reaction that feeds itself, and says so" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Echo.Ring", id: "bell-1")

    # One reaction per level until the bound refuses the next.
    expect(runtime.reactions.size).to eq(Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1)

    # A reaction is appended when it COMPLETES, so the deepest one lands first
    # and the outermost last. Asserting on content rather than position — the
    # ordering is a real property both runtimes share, but it is not what this
    # example is about.
    stopped = runtime.reactions.select { |r| r[:delivered] == false }
    expect(stopped.size).to eq(1)
    expect(stopped.first[:reason]).to match(/reaction depth \d+ reached/)
  end

  it "records a reaction it cannot deliver rather than swallowing it" do
    # pizzas' NotifyOnPurchase reaches ACROSS to a domain nobody loaded. The
    # triggering command already succeeded and its state is saved ; a
    # consequence that cannot be delivered does not retract it. What it must
    # not do is vanish — that silence is the bug this whole change fixes.
    runtime = boot_in_memory
    pizza   = topped_pizza(runtime)
    runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

    expect(runtime.reactions).to contain_exactly(
      hash_including(
        policy:    "NotifyOnPurchase",
        on:        "PizzaPurchased",
        trigger:   "Notifications::Notifications.Send",
        delivered: false
      )
    )
    expect(runtime.reactions.first[:reason]).to match(/no domain "Notifications" loaded/)
  end

  it "leaves the triggering command's own state committed" do
    # The reaction failed above. The purchase did not.
    runtime = boot_in_memory
    pizza   = topped_pizza(runtime)
    runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

    expect(Pizzas::Pizza.find(pizza.id).status).to eq("sold")
  end
end
