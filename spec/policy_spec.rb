
require "spec_helper"

RSpec.describe "a policy" do
  REFLEX_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/reflex.bluebook")

  def boot_reflex
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(REFLEX_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def topped_pizza(runtime)
    # `name:` was written TWICE here — once bare, once as the value object — and
    # Ruby warned on every run while silently keeping the second.
    pizza = runtime.dispatch("Pizzas::Pizza.CreatePizza",
                             name: { value: "Margherita" }, price_cents: { cents: 900 }, size: { value: "small" })
    runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
    pizza
  end

  it "fires the command its event names, and the reaction lands" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")

    expect(Reflex::Light.find("light-1").condition.to_h).to eq(value: "logged")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped",
                     trigger: "Reflex::Light.Log", delivered: true)
    )
  end

  it "fires once per matching event, not once per declaration site" do
    runtime = boot_reflex
    # TWO DISTINCT LIGHTS — `name:` is what Light is identified by; `id:` was
    # never anything but an unread decoy. The second dispatch used to collide
    # with the first (same `name:`, silently overwritten) and still pass,
    # because nothing checked whether a creating command's identity already
    # existed. AlreadyExists (see command_interpreter.rb) caught it.
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-2" }, id: "light-2")

    expect(runtime.reactions.size).to eq(2)
  end

  it "stops a reaction that feeds itself, and says so" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Echo.Install", name: { value: "bell-1" })
    runtime.dispatch("Reflex::Echo.Ring", name: { value: "bell-1" })

    expect(runtime.reactions.size).to eq(Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1)

    stopped = runtime.reactions.select { |r| r[:delivered] == false }
    expect(stopped.size).to eq(1)
    expect(stopped.first[:reason]).to match(/reaction depth \d+ reached/)
  end

  it "records a reaction it cannot deliver rather than swallowing it" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Beacon.Raise", signal: { value: "beacon-1" })

    expect(runtime.reactions).to contain_exactly(
      hash_including(
        policy:    "NotifyOnRaise",
        on:        "Raised",
        trigger:   "Notifications::Notifications.Send",
        delivered: false
      )
    )
    expect(runtime.reactions.first[:reason]).to match(/no domain "Notifications" loaded/)
  end

  it "leaves the triggering command's own state committed" do
    runtime = boot_in_memory
    pizza   = topped_pizza(runtime)
    runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" })

    expect(Pizzas::Pizza.find(pizza.id).status).to eq("sold")
  end
end
