require "spec_helper"

# THE RUNNER BEHIND A PROJECTED CLI — parse against the projection, dispatch,
# and hand back text plus a status. It prints nothing and exits nothing, which
# is what lets this spec call it directly instead of capturing streams.
#
# Against PIZZAS, so nothing here can pass because the runner happens to know
# the chapter it was developed beside.
RSpec.describe Hecksagain::Facade::CliRunner do
  let(:runtime) { boot_in_memory }

  def run(*argv) = described_class.call(runtime: runtime, argv: argv, program: "bin/run")
  def text(*argv) = run(*argv).first
  def status(*argv) = run(*argv).last

  def a_pizza(name = "Margherita")
    run("order.create_pizza", "name=#{name}", "pizza.price_cents.cents=1200", "pizza.size.value=large")
  end

  describe "the usage" do
    it "answers with the projected surface when asked for nothing" do
      expect(text).to include("Pizzas —")
      expect(text).to include("create_pizza")
      expect(status).to eq(0)
    end

    it "answers one verb's help without dispatching it" do
      expect(text("order.create_pizza", "--help")).to include("dispatches Pizzas::Order.CreatePizza")
      expect(runtime.events).to be_empty
    end
  end

  # BOTH SPELLINGS REACH THE SAME VERB.
  describe "naming" do
    it "takes the short form when no other aggregate declares that verb" do
      expect(run("create_pizza", "name=X", "pizza.price_cents.cents=900", "pizza.size.value=small").last).to eq(0)
    end

    it "still takes the aggregate-qualified form" do
      expect(run("order.create_pizza", "name=Y", "pizza.price_cents.cents=900", "pizza.size.value=small").last).to eq(0)
    end
  end

  describe "dispatching" do
    it "answers the record it made, with the events it emitted" do
      output, code = a_pizza

      expect(code).to eq(0)
      answer = JSON.parse(output)
      expect(answer["id"]).to eq("Margherita")
      expect(answer["events"]).to eq(["PizzaCreated"])
      expect(answer.dig("state", "pizza", "price_cents", "cents")).to eq(1200)
    end

    it "reaches an existing record through id" do
      a_pizza
      output, code = run("order.add_topping", "id=Margherita", "topping=Basil", "amount=3")

      expect(code).to eq(0)
      expect(JSON.parse(output).dig("state", "toppings").length).to eq(1)
    end
  end

  describe "asking" do
    it "answers rows, materialised out of their value objects" do
      a_pizza("Bare")
      output, code = run("ask", "order.available")

      expect(code).to eq(0)
      expect(JSON.parse(output).map { |row| row.dig("name", "value") }).to include("Bare")
    end

    it "changes nothing" do
      a_pizza
      before = runtime.events.length
      run("ask", "order.available")

      expect(runtime.events.length).to eq(before)
    end
  end

  # THE REFUSAL IS THE PRODUCT — the chapter's own sentence, and a status a
  # script can branch on.
  describe "refusing" do
    it "hands back the domain's own wording, and a non-zero status" do
      a_pizza
      output, code = run("order.purchase", "id=Margherita", "customer_name=Chris", "amount.cents=1200")

      expect(code).to eq(1)
      expect(output).to match(/topping/i)
    end

    it "names an argument the verb does not take, and points at its help" do
      output, code = run("order.create_pizza", "nmae=Margherita")

      expect(code).to eq(1)
      expect(output).to include(%(no argument "nmae"))
      expect(output).to include("bin/run order.create_pizza --help")
    end

    it "refuses a value the declared type cannot hold" do
      output, code = run("order.create_pizza", "name=X", "pizza.price_cents.cents=lots", "pizza.size.value=large")

      expect(code).to eq(1)
      expect(output).to include("is not Integer")
    end

    # A NEAR MISS IS WORTH MORE THAN THE FULL LIST.
    it "suggests what a misspelling nearly named" do
      output, code = run("order.create_piza")

      expect(code).to eq(1)
      expect(output).to include("no such verb: order.create_piza")
      expect(output).to include("did you mean")
      expect(output).to include("order.create_pizza")
    end

    it "keeps questions and verbs apart when refusing" do
      expect(text("ask", "order.create_pizza")).to include("no such question")
    end
  end
end
