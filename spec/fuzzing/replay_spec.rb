require "spec_helper"
require "hecks/fuzzing"

RSpec.describe "Hecks::Fuzzing::Replay" do
  ROOT_DIR = InMemoryDomain::ROOT unless defined?(ROOT_DIR)
  REPLAY_PIZZAS = File.join(ROOT_DIR, "examples/pizzas")
  REPLAY_CHESS  = File.join(ROOT_DIR, "examples/chess")

  def create_step
    { "verb" => "Pizzas::Order.CreatePizza",
      "args" => { "name"  => { "value" => "Margherita" },
                  "pizza" => { "price_cents" => { "cents" => 1200 },
                               "size"        => { "value" => "large" } } } }
  end

  def topping_step
    { "verb" => "Pizzas::Order.AddTopping",
      "args" => { "amount" => { "value" => 3 }, "topping" => { "value" => "Basil" },
                  "name" => "Margherita" } }
  end

  it "boots fresh, dispatches every step, and reports the same surface bin/run prints" do
    history = Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])

    expect(history[:events].map { |e| e[:name] }).to eq(["PizzaCreated", "ToppingAdded"])
    expect(history[:instances].keys).to eq(["Pizzas::Order#Margherita"])
    expect(history[:refusals]).to be_empty
    expect(history[:bluebook].name).to eq("Pizzas")
  end

  it "records a refusal rather than raising, for a domain refusal" do
    bad = { "verb" => "Pizzas::Order.AddTopping",
            "args" => { "amount" => { "value" => 3 }, "topping" => { "value" => "Basil" },
                        "name" => "nobody-home" } }

    history = Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [bad])

    expect(history[:events]).to be_empty
    expect(history[:refusals].first[:verb]).to eq("Pizzas::Order.AddTopping")
  end

  it "propagates anything that is not a domain refusal — a broken step is a defect, not data" do
    malformed = { "verb" => "Pizzas::Order.CreatePizza", "args" => "not-a-hash" }

    expect { Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [malformed]) }.to raise_error(StandardError)
  end

  it "never touches the domain's own data/ — a fresh tmp copy every call" do
    real_data = File.join(REPLAY_PIZZAS, "data")
    before = Dir.exist?(real_data) ? Dir.children(real_data).sort : nil

    Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step])

    after = Dir.exist?(real_data) ? Dir.children(real_data).sort : nil
    expect(after).to eq(before)
  end

  it "is deterministic — the same steps replayed twice produce the same history" do
    first  = Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])
    second = Hecks::Fuzzing::Replay.call(REPLAY_PIZZAS, [create_step, topping_step])

    comparable = ->(h) { h.except(:bluebook, :bluebooks) }
    expect(comparable.call(first)).to eq(comparable.call(second))
  end

  describe "build_guard_check's own recomputation, against a bare-scalar value-object arg" do
    def chess_start_step
      { "verb" => "Chess::Game.Start", "args" => { "label" => { "value" => "g1" } } }
    end

    def chess_offer_draw_step
      { "verb" => "Chess::Game.OfferDraw",
        "args" => { "label" => { "value" => "g1" }, "by" => { "value" => "white" } } }
    end

    # `by:` arrives as a bare string, the shape the adversarial mutator legitimately
    # produces for a value object with one attribute — real dispatch normalizes it into
    # `{value: "white"}` before evaluating DeclineDraw's shared given.
    def chess_decline_draw_bare_by_step
      { "verb" => "Chess::Game.DeclineDraw", "args" => { "label" => { "value" => "g1" }, "by" => "white" } }
    end

    it "agrees with the real refusal instead of reporting a false divergence" do
      steps = [chess_start_step, chess_offer_draw_step, chess_decline_draw_bare_by_step]
      history = Hecks::Fuzzing::Replay.call(REPLAY_CHESS, steps)

      # White declining its own outstanding offer really is refused — the shared given
      # ("a draw was actually offered, by the other side") compares draw_offer.value
      # against the normalized by.value, both "white".
      decline_refusal = history[:refusals].find { |refusal| refusal[:verb] == "Chess::Game.DeclineDraw" }
      expect(decline_refusal).not_to be_nil
      expect(decline_refusal[:kind]).to eq("Hecks::Runtime::GivenNotMet")

      # build_guard_check's independent recomputation must reach the same verdict. Before
      # normalizing its own copy of `args`, `by.value` walked the raw string ("white") as
      # a substring lookup instead of a value-object field, silently read nil, and reported
      # the given as satisfied — the false positive lifecycle_guard_and_given_violations_
      # are_refused (properties_in_differential) surfaced.
      guard_check = history[:guard_checks].find { |check| check[:verb] == "Chess::Game.DeclineDraw" }
      expect(guard_check).not_to be_nil
      expect(guard_check[:actual_refused]).to be(true)
      expect(guard_check[:recomputed_refused]).to be(true)
      expect(guard_check[:recomputed_kind]).to eq("Hecks::Runtime::GivenNotMet")

      expect(Hecks::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)).to be(true)
    end
  end
end
