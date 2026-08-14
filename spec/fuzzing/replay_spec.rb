
require "spec_helper"
require "hecksagain/fuzzing"

RSpec.describe "Hecksagain::Fuzzing::Replay" do
  ROOT_DIR = InMemoryDomain::ROOT
  REPLAY_PIZZAS = File.join(ROOT_DIR, "examples/pizzas")

  def create_step
    { "verb" => "Pizzas::Order.CreatePizza",
      "args" => { "name" => { "value" => "Margherita" },
                  "pizza" => { "price_cents" => { "cents" => 1200 },
                               "size" => { "value" => "large" } } } }
  end

  def topping_step
    { "verb" => "Pizzas::Order.AddTopping",
      "args" => { "amount" => { "value" => 3 }, "topping" => { "value" => "Basil" },
                  "name" => "Margherita" } }
  end

  it "boots fresh, dispatches every step, and reports the same surface bin/run prints" do
    history = Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])

    expect(history[:events].map { |e| e[:name] }).to eq(["PizzaCreated", "ToppingAdded"])
    expect(history[:instances].keys).to eq(["Pizzas::Order#Margherita"])
    expect(history[:refusals]).to be_empty
    expect(history[:bluebook].name).to eq("Pizzas")
  end

  it "records a refusal rather than raising, for a domain refusal" do
    bad = { "verb" => "Pizzas::Order.AddTopping",
            "args" => { "amount" => { "value" => 3 }, "topping" => { "value" => "Basil" },
                        "name" => "nobody-home" } }

    history = Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [bad])

    expect(history[:events]).to be_empty
    expect(history[:refusals].first[:verb]).to eq("Pizzas::Order.AddTopping")
  end

  it "propagates anything that is not a domain refusal — a broken step is a defect, not data" do
    malformed = { "verb" => "Pizzas::Order.CreatePizza", "args" => "not-a-hash" }

    expect { Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [malformed]) }.to raise_error(StandardError)
  end

  it "never touches the domain's own data/ — a fresh tmp copy every call" do
    real_data = File.join(REPLAY_PIZZAS, "data")
    before = Dir.exist?(real_data) ? Dir.children(real_data).sort : nil

    Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step])

    after = Dir.exist?(real_data) ? Dir.children(real_data).sort : nil
    expect(after).to eq(before)
  end

  it "is deterministic — the same steps replayed twice produce the same history" do
    first  = Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])
    second = Hecksagain::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])

    comparable = ->(h) { h.reject { |k, _| k == :bluebook || k == :bluebooks } }
    expect(comparable.call(first)).to eq(comparable.call(second))
  end
end
