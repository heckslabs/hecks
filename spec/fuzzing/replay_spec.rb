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

  it "boots fresh, dispatches every step, and reports the same surface hecks run prints" do
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

  # The sibling gap to build_guard_check's own: build_mutation_trace feeds the same
  # raw, un-normalized args into dispatch_and_mutations.rb's independent append/remove
  # recompute. `EntityListMutations::Board.TaggedList` (spec/fixtures/
  # entity_list_mutations) declares `PriceTier`, a list_of value-object element type
  # with its own `default: "standard"` field, plus `AddPrice`/`RemovePrice` — the two
  # commands this shape can diverge on.
  describe "build_mutation_trace's own recomputation, against a caller-omitted value-object default" do
    unless defined?(REPLAY_ENTITY_LIST_MUTATIONS)
      REPLAY_ENTITY_LIST_MUTATIONS = File.join(ROOT_DIR, "spec/fixtures/entity_list_mutations")
    end

    def open_and_add_list_steps
      [{ "verb" => "EntityListMutations::Board.OpenBoard", "args" => { "name" => { "value" => "b1" } } },
       { "verb" => "EntityListMutations::Board.AddList",
         "args" => { "name" => "b1", "label" => { "value" => "todo" } } }]
    end

    # `price_name` only — `tier` is never mapped by `AddPrice`'s own `append:`, relying
    # on PriceTier's own declared default to fill it, the same way real dispatch's
    # `Value.build` does.
    def add_price_step
      { "verb" => "EntityListMutations::Board.TaggedList.AddPrice",
        "args" => { "name" => "b1", "label" => { "value" => "todo" }, "price_name" => "widget" } }
    end

    # A partial `price:`, naming only `name` — real dispatch fills `tier` before
    # matching, so this really does remove the element AddPrice just appended.
    def remove_price_partial_step
      { "verb" => "EntityListMutations::Board.TaggedList.RemovePrice",
        "args" => { "name" => "b1", "label" => { "value" => "todo" }, "price" => { "name" => "widget" } } }
    end

    it "agrees that AddPrice's after-state carries the value object's own default" do
      steps = open_and_add_list_steps + [add_price_step]
      history = Hecks::Fuzzing::Replay.call(REPLAY_ENTITY_LIST_MUTATIONS, steps)

      expect(history[:refusals]).to be_empty

      trace = history[:mutation_traces].find { |t| t[:verb] == "EntityListMutations::Board.TaggedList.AddPrice" }
      expect(trace).not_to be_nil
      # Real dispatch's own after-state: `tier` defaulted to "standard" though no
      # command argument ever named it.
      expect(trace[:after][:prices]).to eq([{ name: "widget", tier: "standard" }])

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end

    it "agrees that RemovePrice's partial value still matches the fully-defaulted element" do
      steps = open_and_add_list_steps + [add_price_step, remove_price_partial_step]
      history = Hecks::Fuzzing::Replay.call(REPLAY_ENTITY_LIST_MUTATIONS, steps)

      expect(history[:refusals]).to be_empty

      trace = history[:mutation_traces].find { |t| t[:verb] == "EntityListMutations::Board.TaggedList.RemovePrice" }
      expect(trace).not_to be_nil
      # Real dispatch really did remove it: a partial `price:` still resolves to the
      # fully-defaulted PriceTier the stored element carries.
      expect(trace[:after][:prices]).to eq([])

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end
  end

  # The same sibling gap, on the querying side: `paging_offset_partitions_correctly`
  # recomputed eligibility from a query's raw args. `Board.highlight_count` is never
  # set by any command — every board carries only `ListCount`'s own `default: 0` — and
  # `ByHighlightCount` queries it with a caller arg that omits `ListCount`'s sole field
  # entirely (`{}`), the shape the language's ambiguous-comparison guard cannot rule
  # out for a single-attribute value object.
  describe "paging_offset_partitions_correctly's own recomputation, against a caller-omitted query default" do
    it "agrees that a board with the defaulted highlight_count is eligible" do
      steps = [{ "verb" => "EntityListMutations::Board.OpenBoard", "args" => { "name" => { "value" => "b1" } } },
               { "query" => "EntityListMutations::Board.ByHighlightCount", "args" => { "count" => {} } }]
      history = Hecks::Fuzzing::Replay.call(REPLAY_ENTITY_LIST_MUTATIONS, steps)

      expect(history[:refusals]).to be_empty

      asked = history[:queries].find { |q| q[:query] == "EntityListMutations::Board.ByHighlightCount" }
      expect(asked).not_to be_nil
      # Real dispatch really did match: an omitted `count:` still resolves to
      # `ListCount`'s own default, 0 — the same value every fresh board carries.
      expect(asked[:rows].map { |row| row[:id] }).to eq(["b1"])

      expect(Hecks::Fuzzing::Properties.paging_offset_partitions_correctly(history)).to be(true)
    end
  end
end
