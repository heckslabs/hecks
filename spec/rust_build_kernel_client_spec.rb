require "hecks/rust_build/kernel_client"
require_relative "support/rust_conformance_helpers"

# The kernel's host protocol (ADR 0189) through the Ruby client: a dispatch round-trips, a
# refusal is `ok: false` with an error (ADR 0186), sessions keep their own state, and the kernel
# can ask the host for a fact in the middle of a dispatch. Runs against the pizzas kernel built
# for this checkout.
RSpec.describe Hecks::RustBuild::KernelClient, :io do
  include RustConformanceHelpers

  let(:client) { nil }

  let(:binary) do
    build_rust_for("pizzas", File.join(InMemoryDomain::ROOT, "rust")) ||
      skip("rust/Cargo.toml has no pizzas feature")
  end

  def create
    {
      "name"  => { "value" => "margherita" },
      "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } }
    }
  end

  def basil = { "name" => "margherita", "topping" => { "value" => "Basil" } }

  # What the host builds from the domain's IR; here the one fact the host will be asked for.
  def needs = { "Pizzas::Order.AddTopping" => [{ "fact" => "amount", "type" => "ToppingAmount" }] }

  # The record the kernel holds for the pizza the examples create, keyed `Aggregate#id`.
  def margherita(client, session: nil)
    message = { "instances" => true }
    message["session"] = session if session
    client.call(message).fetch("instances")["Pizzas::Order#margherita"]
  end

  after { client&.close }

  describe "a dispatch" do
    let(:client) { described_class.open(binary) }

    it "round-trips and returns the events it raised", :aggregate_failures do
      answer = client.dispatch("Pizzas::Order.CreatePizza", create)

      expect(client.protocol).to eq(1)
      expect(answer["ok"]).to be(true)
      expect(answer["events"]).not_to be_empty
    end

    it "is refused as ok false with an error and no supported flag", :aggregate_failures do
      answer = client.dispatch("Pizzas::Order.AddTopping", basil.merge("amount" => { "value" => 2 }))

      expect(answer["ok"]).to be(false)
      expect(answer["error"]).to be_a(String).and(satisfy { |text| !text.empty? })
      expect(answer).not_to have_key("supported")
    end

    it "is refused when the verb is unknown", :aggregate_failures do
      answer = client.dispatch("Pizzas::Order.NoSuchCommand", {})

      expect(answer["ok"]).to be(false)
      expect(answer["error"]).to be_a(String)
    end
  end

  describe "sessions" do
    let(:client) { described_class.open(binary) }

    it "keep their own state", :aggregate_failures do
      client.open_session("a")
      client.dispatch("Pizzas::Order.CreatePizza", create, session: "a")

      expect(margherita(client, session: "a")).not_to be_nil
      expect(margherita(client)).to be_nil
    end

    it "refuse a step once closed", :aggregate_failures do
      client.open_session("a")

      expect(client.close_session("a")["ok"]).to be(true)
      expect(client.dispatch("Pizzas::Order.CreatePizza", create, session: "a")["error"])
        .to include("no such session")
    end

    it "refuse a second open of the same name" do
      client.open_session("a")

      expect(client.open_session("a")["error"]).to include("already open")
    end
  end

  describe "a callback" do
    let(:asked) { [] }
    let(:client) do
      described_class.open(binary, needs: needs) do |fact, type, verb|
        asked << [fact, type, verb]
        { "value" => 3 }
      end
    end

    it "lets the kernel ask the host for a fact in the middle of a dispatch", :aggregate_failures do
      client.dispatch("Pizzas::Order.CreatePizza", create)
      answer = client.dispatch("Pizzas::Order.AddTopping", basil)

      expect(answer["ok"]).to be(true)
      expect(asked).to eq([["amount", "ToppingAmount", "Pizzas::Order.AddTopping"]])
      expect(margherita(client).fetch("toppings")).to eq([{ "name" => "Basil", "amount" => 3 }])
    end

    it "does not ask for a fact the caller supplied", :aggregate_failures do
      client.dispatch("Pizzas::Order.CreatePizza", create)
      client.dispatch("Pizzas::Order.AddTopping", basil.merge("amount" => { "value" => 2 }))

      expect(asked).to be_empty
    end
  end

  describe "a callback the host cannot answer" do
    let(:client) { described_class.open(binary, needs: needs) { |_fact, _type, _verb| nil } }

    it "leaves the fact out, so the dispatch is refused as ok false", :aggregate_failures do
      client.dispatch("Pizzas::Order.CreatePizza", create)
      answer = client.dispatch("Pizzas::Order.AddTopping", basil)

      expect(answer["ok"]).to be(false)
      expect(answer["error"]).to be_a(String)
    end
  end

  describe "version negotiation" do
    it "refuses a client that speaks no version the kernel does" do
      expect { described_class.open(binary, protocols: [2]) }
        .to raise_error(described_class::Unreachable, /no common protocol/)
    end
  end
end
