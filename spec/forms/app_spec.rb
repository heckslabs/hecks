require "spec_helper"
require "hecksagain/forms"
require "rack/test"
require "json"

RSpec.describe Hecksagain::Forms::App do
  include Rack::Test::Methods

  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")
  FORMS_BLUEBOOK = File.join(InMemoryDomain::ROOT, "lib/hecksagain/forms/examples/banking_console.bluebook")

  # The same rebind spec/facade/handle_spec.rb already uses —
  # [[feedback_specs_prefer_memory_adapter]] — banking.hecksagon itself
  # binds "Heki", a real store no spec should need.
  def app
    @app ||= begin
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(BANKING_BLUEBOOK)
        Kernel.load(FORMS_BLUEBOOK)
        Hecks.hecksagon("Banking") do
          ::Banking::Customer.persisted_by("Memory")
          ::Banking::Account.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecksagain::Forms::App.for(registry: registry, app_name: "BankingConsole")
    end
  end

  def register_ada
    post "/Banking/Customer/Register.html", "reference.value" => "c1", "name.given" => "Ada",
                                              "name.family" => "Lovelace", "email.address" => "ada@example.com"
  end

  describe "content negotiation by extension" do
    it "answers HTML for .html" do
      get "/Banking/Customer/Register.html"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("text/html")
      expect(last_response.body).to include("<form")
    end

    it "answers the command's own declared shape as JSON for the bare path" do
      get "/Banking/Customer/Register"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("Register")
      expect(body["attributes"].map { |a| a["name"] }).to contain_exactly("reference", "name", "email")
    end
  end

  describe "a command's HTML form" do
    it "GET renders an empty form with every declared field" do
      get "/Banking/Customer/Register.html"
      expect(last_response.body).to include('name="reference.value"')
      expect(last_response.body).to include('name="name.given"')
      expect(last_response.body).to include('type="email"') # email.address's own pattern
    end

    it "POST dispatches the command and redirects to the new record (PRG)" do
      register_ada
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c1.html")
    end

    it "POST with an invalid value re-renders the SAME form, sticky, with the refusal's own message" do
      post "/Banking/Customer/Register.html", "reference.value" => "", "name.given" => "Ada",
                                                "name.family" => "Lovelace", "email.address" => "ada@example.com"
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include("InvariantViolation")
      expect(last_response.body).to include("customer reference is present")
      # sticky — the value the caller actually typed survives the re-render
      expect(last_response.body).to include('value="Ada"')
    end

    it "POST as JSON dispatches and answers 201 with the record's state" do
      post "/Banking/Customer/Register", "reference.value" => "c9", "name.given" => "Grace",
                                          "name.family" => "Hopper", "email.address" => "grace@example.com"
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to eq("c9")
    end
  end

  describe "a query's HTML view" do
    it "GET with no params shows the canonical link template but runs nothing" do
      get "/Banking/Account/Overdrawn.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("floor.cents={floor.cents}")
      expect(last_response.body).not_to include("<h2>Results")
    end

    it "GET with params runs the query and shows a results table" do
      get "/Banking/Account/Overdrawn.html?floor.cents=0&floor.currency=USD"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("<h2>Results")
    end
  end

  describe "a record's own page" do
    before { register_ada }

    it "shows its state and only the commands its lifecycle currently allows" do
      get "/Banking/Customer/c1.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("status: active")
      expect(last_response.body).to include(">Suspend<")
      expect(last_response.body).not_to include(">Reinstate<") # only valid from "suspended"
    end

    it "answers 404 (both formats) for an id that does not exist" do
      get "/Banking/Customer/nope.html"
      expect(last_response.status).to eq(404)

      get "/Banking/Customer/nope"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)["error"]).to eq("NotFound")
    end
  end

  describe "an aggregate's index page" do
    it "lists every creating command and every existing record" do
      register_ada
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Register")
      expect(last_response.body).to include("/Banking/Customer/c1.html")
    end
  end

  it "refuses a chapter this app does not expose" do
    get "/Deploy/Anything.html"
    expect(last_response.status).to eq(404)
  end
end
