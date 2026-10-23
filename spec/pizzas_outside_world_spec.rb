require "spec_helper"
require "rack/test"
require "json"
require_relative "../examples/pizzas/adapters/payment_webhook"
require_relative "../examples/pizzas/adapters/fake_processor"

# The pizzas example's two driving adapters, reached the way a browser and a payment processor
# reach them: through `examples/pizzas/config.ru`, over Rack.
RSpec.describe "Pizzas, connected to the outside world" do
  include Rack::Test::Methods

  PIZZAS_CONFIG_RU = File.join(InMemoryDomain::ROOT, "examples/pizzas/config.ru")
  PIZZAS_WEBHOOK_SECRET = "whsec_spec".freeze

  def app
    @app ||= begin
      ENV["PAYMENT_WEBHOOK_SECRET"] = PIZZAS_WEBHOOK_SECRET
      Rack::Builder.parse_file(PIZZAS_CONFIG_RU)
    ensure
      ENV.delete("PAYMENT_WEBHOOK_SECRET")
    end
  end

  def json_body = JSON.parse(last_response.body)

  def create_pizza(name, cents = 1200)
    post "/Pizzas/Order/CreatePizza.html", "name.value" => name, "pizza.price_cents.cents" => cents.to_s,
                                           "pizza.size.value" => "large"
  end

  def add_basil(name) = post("/Pizzas/Order/AddTopping.html", "to" => name, "topping.value" => "Basil", "amount.value" => "2")

  def topped_pizza(name)
    create_pizza(name)
    add_basil(name)
  end

  def order(name)
    get "/Pizzas/Order/#{name}.json"
    json_body
  end

  def deliver(body, signature)
    post "/webhooks/payments", body, "CONTENT_TYPE" => "application/json", "HTTP_STRIPE_SIGNATURE" => signature
  end

  def pay(pizza, cents, processor: PizzaShop::FakeProcessor.new(secret: PIZZAS_WEBHOOK_SECRET), at: Time.now)
    deliver(*processor.payment_succeeded(pizza: pizza, customer_name: "Chris", cents: cents, at: at))
  end

  describe "the web forms (the Json driving adapter)" do
    it "lists Pizzas as the one exposed domain", :aggregate_failures do
      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Pizzas")
    end

    it "creates a pizza from a submitted form and redirects to it", :aggregate_failures do
      create_pizza("Margherita")
      expect(last_response.status).to eq(303).or eq(302)
      expect(order("Margherita")).to include("status" => "available", "toppings" => [])
    end

    it "sells a topped pizza through the Purchase form" do
      topped_pizza("Funghi")
      post "/Pizzas/Order/Purchase.html", "to" => "Funghi", "customer_name.value" => "Chris", "amount.cents" => "1200"
      expect(order("Funghi")).to include("status" => "sold", "customer_name" => "Chris")
    end

    it "answers a refused purchase with the form again and the rule's words", :aggregate_failures do
      create_pizza("Bare", 900)
      post "/Pizzas/Order/Purchase.html", "to" => "Bare", "customer_name.value" => "Chris", "amount.cents" => "900"
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include("a pizza needs at least one topping")
    end
  end

  describe "the payment webhook (the processor's way in, through PaymentGateway.Receive)" do
    it "sells the pizza when the processor reports a payment that covers it", :aggregate_failures do
      topped_pizza("Paid")
      pay("Paid", 1200)
      expect(json_body).to include("sold" => true, "events" => ["PizzaPaymentReceived"])
      expect(order("Paid")).to include("status" => "sold", "customer_name" => "Chris")
    end

    it "records an underpayment but sells nothing, naming the rule that refused it", :aggregate_failures do
      topped_pizza("Short")
      pay("Short", 500)
      expect(json_body).to include("sold" => false, "refused" => "Purchase refused — the payment covers the price")
      expect(order("Short")["status"]).to eq("available")
    end

    it "sells nothing for a pizza with no toppings" do
      create_pizza("Plain")
      pay("Plain", 1200)
      expect(json_body["refused"]).to include("a pizza needs at least one topping")
    end

    it "refuses a delivery signed with another secret before the domain hears of it", :aggregate_failures do
      topped_pizza("Forged")
      pay("Forged", 1200, processor: PizzaShop::FakeProcessor.new(secret: "not-the-secret"))
      expect(last_response.status).to eq(401)
      expect(order("Forged")["status"]).to eq("available")
    end

    it "refuses a delivery signed too long ago, as a replay" do
      topped_pizza("Stale")
      pay("Stale", 1200, at: Time.now - 3600)
      expect(last_response.status).to eq(401)
    end

    it "refuses a body changed after it was signed" do
      processor = PizzaShop::FakeProcessor.new(secret: PIZZAS_WEBHOOK_SECRET)
      body, signature = processor.payment_succeeded(pizza: "X", customer_name: "C", cents: 1)
      deliver("#{body} ", signature)
      expect(last_response.status).to eq(401)
    end

    it "acknowledges an event type it does not act on" do
      body = JSON.generate(type: "payment_intent.created")
      deliver(body, PizzaShop::PaymentSignature.sign(PIZZAS_WEBHOOK_SECRET, body))
      expect(json_body).to eq("ok" => true, "ignored" => "payment_intent.created")
    end

    it "refuses a payment that does not say which pizza it is for" do
      body = JSON.generate(type: PizzaShop::PaymentWebhook::SUCCEEDED, data: { object: { amount_received: 1200 } })
      deliver(body, PizzaShop::PaymentSignature.sign(PIZZAS_WEBHOOK_SECRET, body))
      expect(last_response.status).to eq(422)
    end
  end
end
