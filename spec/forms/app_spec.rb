require "spec_helper"
require "hecks/forms"
require "rack/test"
require "json"
require "uri"
require_relative "../support/memory_ports"

RSpec.describe Hecks::Forms::App do
  include Rack::Test::Methods

  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)
  FORMS_BLUEBOOK = File.join(InMemoryDomain::ROOT, "lib/hecks/forms/examples/banking_console.bluebook")

  # Rebinds persistence to memory: banking.hecksagon binds "Heki", a real store.
  def app
    @app ||= begin
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { load_banking_console }
      registry.verify!
      Hecks::Forms::App.for(registry: registry, app_name: "BankingConsole")
    end
  end

  def load_banking_console
    MemoryPorts.load!
    load_bluebook_files(BANKING_BLUEBOOK)
    Kernel.load(FORMS_BLUEBOOK)
    bind_banking_to_memory
  end

  def bind_banking_to_memory
    Hecks.hecksagon("Banking") do
      attaches "Governance"
      Banking::Customer.persisted_by("Memory")
      Banking::Account.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def register_customer(id)
    post "/Banking/Customer/Register.html", "reference.value" => id, "name.given" => "Ada",
                                              "name.family" => "Lovelace", "email.address" => "ada@example.com"
  end

  def register_ada = register_customer("c1")

  def json_body = JSON.parse(last_response.body)

  def post_json(payload)
    post "/Banking/Customer/Register", JSON.generate(with: payload), "CONTENT_TYPE" => "application/json"
  end

  describe "content negotiation by extension" do
    it "answers HTML for .html", :aggregate_failures do
      get "/Banking/Customer/Register.html"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("text/html")
      expect(last_response.body).to include("<form")
    end

    it "answers the command's own declared shape as JSON for the bare path", :aggregate_failures do
      get "/Banking/Customer/Register"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      expect(json_body["name"]).to eq("Register")
      expect(json_body["attributes"].map { |a| a["name"] }).to contain_exactly("reference", "name", "email")
    end
  end

  describe "a command's HTML form" do
    it "GET renders an empty form with every declared field", :aggregate_failures do
      get "/Banking/Customer/Register.html"
      expect(last_response.body).to include('name="reference.value"')
      expect(last_response.body).to include('name="name.given"')
      expect(last_response.body).to include('type="email"') # email.address's own pattern
    end

    it "POST dispatches the command and redirects to the new record (PRG)", :aggregate_failures do
      register_ada
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c1.html")
    end

    it "routes an existing aggregate through to, outside the command's facts", :aggregate_failures do
      register_ada

      get "/Banking/Customer/Close.html?to=c1"
      expect(last_response.body).to include('name="to"')
      expect(last_response.body).not_to include('name="id"')
    end

    it "closes the aggregate that to names", :aggregate_failures do
      register_ada
      post "/Banking/Customer/Close.html", "to" => "c1"
      expect(last_response.status).to eq(302)

      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
    end

    it "POST with an invalid value re-renders the SAME form, sticky, with the refusal's own message", :aggregate_failures do
      register_customer("")
      expect(last_response.status).to eq(422)
      # Attribute coercion runs before invariants, so a blank reference fails
      # CustomerNumber's `pattern:` as a TypeMismatch, not an InvariantViolation.
      expect(last_response.body).to include("TypeMismatch")
      expect(last_response.body).to include("CustomerNumber.value must match")
      # sticky: the typed value survives the re-render
      expect(last_response.body).to include('value="Ada"')
    end

    it "POST as JSON dispatches and answers 201 with the record's state", :aggregate_failures do
      post "/Banking/Customer/Register", "reference.value" => "c9", "name.given" => "Grace",
                                          "name.family" => "Hopper", "email.address" => "grace@example.com"
      expect(last_response.status).to eq(201)
      expect(json_body["id"]).to eq("c9")
    end

    it "accepts a real JSON command envelope", :aggregate_failures do
      post_json(reference: { value: "c-json" }, name: { given: "JSON", family: "Caller" },
                email: { address: "json@example.com" })

      expect(last_response.status).to eq(201), last_response.body
      expect(json_body["id"]).to eq("c-json")
    end

    it "keeps legacy id as an accepted but unrendered form input", :aggregate_failures do
      register_ada

      post "/Banking/Customer/Close.html", "id" => "c1"

      expect(last_response.status).to eq(302)
      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
    end
  end

  describe "a query's HTML view" do
    it "GET with no params shows the canonical link template but runs nothing", :aggregate_failures do
      get "/Banking/Account/Overdrawn.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("floor.cents={floor.cents}")
      expect(last_response.body).not_to include("<h2>Results")
    end

    it "GET with params runs the query and shows a results table", :aggregate_failures do
      get "/Banking/Account/Overdrawn.html?floor.cents=0&floor.currency=USD"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("<h2>Results")
    end
  end

  # Pins that `run_query` rescues JSON::ParserError from a malformed line in a
  # multi-attribute value-object list parameter (`Params.extract_list`).
  # No Banking query takes one, so this builds a small dedicated domain.
  describe "a query with a list-of-value-object parameter" do
    def app
      @app ||= begin
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          MemoryPorts.load!
          declare_list_query_bluebook
          Hecks.hecksagon("ListQueryDomain") { ListQueryDomain::Basket.persisted_by("Memory") }
        end
        registry.verify!
        Hecks::Forms::App.new(registry: registry, exposed: ["ListQueryDomain"])
      end
    end

    def declare_list_query_bluebook
      basket = basket_definition
      Hecks.bluebook("ListQueryDomain") { aggregate("Basket", &basket) }
    end

    def item_definition
      proc do
        attribute :name, String
        attribute :qty, Integer
      end
    end

    def basket_definition
      item = item_definition
      proc do
        identified_by :basket_id
        value_object("Item", &item)

        query("BySpecs") do
          attribute :items, list_of(Item)
          limit 10
        end
      end
    end

    it "answers 422 (not 500) for a malformed line, bare/JSON path", :aggregate_failures do
      get "/ListQueryDomain/Basket/BySpecs?items=not-json"
      expect(last_response.status).to eq(422)
      expect(json_body["error"]).to eq("ParserError")
    end

    it "answers 422 (not 500) for a malformed line, .html path, with the error rendered", :aggregate_failures do
      get "/ListQueryDomain/Basket/BySpecs.html?items=not-json"
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include("ParserError")
    end

    it "still runs cleanly for a well-formed line", :aggregate_failures do
      get "/ListQueryDomain/Basket/BySpecs?items=#{URI.encode_www_form_component(JSON.generate(name: "bolt", qty: 3))}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
    end
  end

  describe "a record's own page" do
    before { register_ada }

    it "shows its state and only the commands its lifecycle currently allows", :aggregate_failures do
      get "/Banking/Customer/c1.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("status: active")
      expect(last_response.body).to include(">Suspend<")
      expect(last_response.body).not_to include(">Reinstate<") # only valid from "suspended"
    end

    it "answers 404 (both formats) for an id that does not exist", :aggregate_failures do
      get "/Banking/Customer/nope.html"
      expect(last_response.status).to eq(404)

      get "/Banking/Customer/nope"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)["error"]).to eq("NotFound")
    end
  end

  # A free-form record id can equal a command name ("Close"); GET must resolve
  # to the record first. POST never views a record, so commands stay unaffected.
  describe "a record whose id collides with a command/query name" do
    def register_named(id) = register_customer(id)

    it "the record's own detail page (.html) still wins over a command sharing its name", :aggregate_failures do
      register_named("Close") # "Close" is also Customer's own command name

      get "/Banking/Customer/Close.html"
      expect(last_response.status).to eq(200)
      # record state, not a command form
      expect(last_response.body).to include("status: active")
      expect(last_response.body).not_to include("<form")
    end

    it "the record's own detail page (bare/JSON) still wins over a command sharing its name", :aggregate_failures do
      register_named("Close")

      get "/Banking/Customer/Close"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      expect(JSON.parse(last_response.body)["id"]).to eq("Close")
    end

    it "the record's own detail page still wins over a query sharing its name", :aggregate_failures do
      register_named("Suspended") # "Suspended" is also Customer's own query name

      get "/Banking/Customer/Suspended.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("status: active")
      expect(last_response.body).not_to include("<h2>Results")
    end

    it "does not disturb submitting the command for a DIFFERENT (non-colliding) record", :aggregate_failures do
      register_named("Close")
      register_ada # id "c1", no collision

      post "/Banking/Customer/Close.html", "to" => "c1"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c1.html")
    end

    it "closes the non-colliding record the command names", :aggregate_failures do
      register_named("Close")
      register_ada
      post "/Banking/Customer/Close.html", "to" => "c1"

      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
    end
  end

  describe "an aggregate's index page" do
    it "lists every creating command and every existing record", :aggregate_failures do
      register_ada
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Register")
      expect(last_response.body).to include("/Banking/Customer/c1.html")
    end
  end

  # CustomerNumber's `pattern:` only forbids whitespace, so a dotted id such as
  # `c.1` is legal and must not be mistaken for a format extension.
  describe "a record id containing a dot" do
    def register_dotted = register_customer("c.1")

    it "redirects to the dotted id's own detail page, not a truncated one", :aggregate_failures do
      register_dotted
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c.1.html")
    end

    it "the detail page (.html) resolves the full id, not just the part before the first dot", :aggregate_failures do
      register_dotted
      get "/Banking/Customer/c.1.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("c.1")
    end

    it "the bare/JSON path resolves the full id", :aggregate_failures do
      register_dotted
      get "/Banking/Customer/c.1"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      expect(JSON.parse(last_response.body)["id"]).to eq("c.1")
    end

    it "an explicit .json request resolves the full id", :aggregate_failures do
      register_dotted
      get "/Banking/Customer/c.1.json"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq("c.1")
    end

    it "the index page links to the dotted id's own (unambiguous) detail page", :aggregate_failures do
      register_dotted
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("/Banking/Customer/c.1.html")
    end
  end

  # HTML-escaping is not enough: a raw `&`, `+`, `?` or `#` in an href still
  # corrupts the link, and CustomerNumber's pattern permits all four.
  describe "a record id containing URL-syntax characters" do
    MALICIOUS_ID = "a&b+c?d#e".freeze

    def register_malicious = register_customer(MALICIOUS_ID)

    let(:encoded_id) { URI.encode_www_form_component(MALICIOUS_ID) }

    # `get(path)` parses "?"/"#" as query/fragment and leaves percent-escapes
    # encoded, unlike a real Rack server, which decodes them into PATH_INFO.
    # Setting PATH_INFO directly hands the app what production would.
    def get_with_raw_path_info(path)
      get "/", {}, "PATH_INFO" => path
    end

    it "percent-encodes the id in the redirect Location after create", :aggregate_failures do
      register_malicious
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/#{encoded_id}.html")
    end

    it "percent-encodes the id in the index page's href", :aggregate_failures do
      register_malicious
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("href=\"/Banking/Customer/#{encoded_id}.html\"")
    end

    it "HTML-escapes the id as the index page's link text", :aggregate_failures do
      register_malicious
      get "/Banking/Customer.html"
      # link text is HTML-escaped, not percent-encoded
      expect(last_response.body).to include(Hecks::Forms::Escape.html(MALICIOUS_ID))
      # the raw id must never appear unescaped
      expect(last_response.body).not_to include(%(>#{MALICIOUS_ID}<))
    end

    it "resolves via the id a browser decodes back out of the percent-encoded href", :aggregate_failures do
      register_malicious
      get_with_raw_path_info("/Banking/Customer/#{MALICIOUS_ID}.html")
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(Hecks::Forms::Escape.html(MALICIOUS_ID))
    end

    it "percent-encodes the id in a record's own command links (?to=)" do
      register_malicious
      get_with_raw_path_info("/Banking/Customer/#{MALICIOUS_ID}.html")
      expect(last_response.body).to include("?to=#{encoded_id}")
    end
  end

  it "refuses a chapter this app does not expose" do
    get "/Deploy/Anything.html"
    expect(last_response.status).to eq(404)
  end

  it "explicitly refuses entity command URLs until the forms router can address them", :aggregate_failures do
    post "/Banking/SafeDepositBox/Visit/Annotate.html"

    expect(last_response.status).to eq(404)
    expect(last_response.body).to include("entity command routes are not supported")
    expect(last_response.body).to include("to.aggregate and to.entity")
  end
end
