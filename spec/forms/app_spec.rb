require "spec_helper"
require "hecks/forms"
require "rack/test"
require "json"
require "uri"

RSpec.describe Hecks::Forms::App do
  include Rack::Test::Methods

  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR
  FORMS_BLUEBOOK = File.join(InMemoryDomain::ROOT, "lib/hecks/forms/examples/banking_console.bluebook")

  # The same rebind spec/facade/handle_spec.rb already uses —
  # [[feedback_specs_prefer_memory_adapter]] — banking.hecksagon itself
  # binds "Heki", a real store no spec should need.
  def app
    @app ||= begin
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(BANKING_BLUEBOOK)
        Kernel.load(FORMS_BLUEBOOK)
        Hecks.hecksagon("Banking") do
          uses_framework "Governance"
          ::Banking::Customer.persisted_by("Memory")
          ::Banking::Account.persisted_by("Memory")
        end
        Hecks.hecksagon("Governance") do
          ::Governance::RoleAssignment.persisted_by("Memory")
          ::Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecks::Forms::App.for(registry: registry, app_name: "BankingConsole")
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

    it "routes an existing aggregate through to, outside the command's facts" do
      register_ada

      get "/Banking/Customer/Close.html?to=c1"
      expect(last_response.body).to include('name="to"')
      expect(last_response.body).not_to include('name="id"')

      post "/Banking/Customer/Close.html", "to" => "c1"
      expect(last_response.status).to eq(302)

      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
    end

    it "POST with an invalid value re-renders the SAME form, sticky, with the refusal's own message" do
      post "/Banking/Customer/Register.html", "reference.value" => "", "name.given" => "Ada",
                                                "name.family" => "Lovelace", "email.address" => "ada@example.com"
      expect(last_response.status).to eq(422)
      # CustomerNumber carries a `pattern:` (the whitespace-only sweep) as
      # well as its "a customer reference is present" invariant — attribute
      # coercion runs before invariants, so a blank reference is refused as
      # a TypeMismatch, not an InvariantViolation.
      expect(last_response.body).to include("TypeMismatch")
      expect(last_response.body).to include("CustomerNumber.value must match")
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

    it "accepts a real JSON command envelope" do
      post "/Banking/Customer/Register",
           JSON.generate(with: {
                           reference: { value: "c-json" },
                           name:      { given: "JSON", family: "Caller" },
                           email:     { address: "json@example.com" }
                         }),
           "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(201), last_response.body
      expect(JSON.parse(last_response.body)["id"]).to eq("c-json")
    end

    it "keeps legacy id as an accepted but unrendered form input" do
      register_ada

      post "/Banking/Customer/Close.html", "id" => "c1"

      expect(last_response.status).to eq(302)
      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
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

  # L10 (docs/audits/2026-08-10-main-bug-audit.md) — `run_query`'s own
  # rescue clause listed every domain refusal plus ArgumentError/TypeError,
  # but not `JSON::ParserError` — the one error a malformed line in a
  # list-of-VALUE-OBJECT query parameter actually raises
  # (`Params.extract_list`'s own JSON fallback for a multi-attribute list
  # element; a single-attribute VO like Banking's own `Tag`/`CustomerNumber`
  # unwraps to a plain scalar and never hits that branch at all). Both
  # command submission paths already rescue it (`submit_command`,
  # `command_json`); this was the same defect on the query side. No
  # Banking fixture query happens to take a list-of-multi-attribute-VO
  # parameter, so this spins up a tiny dedicated domain rather than
  # bending a shared fixture other specs also depend on.
  describe "a query with a list-of-value-object parameter" do
    def app
      @app ||= begin
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)

          Hecks.bluebook("ListQueryDomain") do
            aggregate("Basket") do
              identified_by :basket_id

              value_object("Item") do
                attribute :name, String
                attribute :qty, Integer
              end

              query("BySpecs") do
                attribute :items, list_of(Item)
              end
            end
          end

          Hecks.hecksagon("ListQueryDomain") do
            ::ListQueryDomain::Basket.persisted_by("Memory")
          end
        end
        registry.verify!
        Hecks::Forms::App.new(registry: registry, exposed: ["ListQueryDomain"])
      end
    end

    it "answers 422 (not 500) for a malformed line, bare/JSON path" do
      get "/ListQueryDomain/Basket/BySpecs?items=not-json"
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body["error"]).to eq("ParserError")
    end

    it "answers 422 (not 500) for a malformed line, .html path, with the error rendered" do
      get "/ListQueryDomain/Basket/BySpecs.html?items=not-json"
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include("ParserError")
    end

    it "still runs cleanly for a well-formed line" do
      get "/ListQueryDomain/Basket/BySpecs?items=#{URI.encode_www_form_component(JSON.generate(name: 'bolt', qty: 3))}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
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

  # L11 (docs/audits/2026-08-10-main-bug-audit.md) — a record's own id is
  # free-form (S3) and can collide with a command/query name on its own
  # aggregate ("Close" is one of Customer's own command names). Checking
  # the verb first (the old order) meant such a record's own detail page
  # could never be reached again — a GET always resolved to the
  # command/query instead. POST never views a record at all
  # (`record_route` only ever answers GET), so command submission for a
  # DIFFERENT record must stay unaffected.
  describe "a record whose id collides with a command/query name" do
    def register_named(id)
      post "/Banking/Customer/Register.html", "reference.value" => id, "name.given" => "Ada",
                                                "name.family" => "Lovelace", "email.address" => "ada@example.com"
    end

    it "the record's own detail page (.html) still wins over a command sharing its name" do
      register_named("Close") # "Close" is also Customer's own command name

      get "/Banking/Customer/Close.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("status: active") # the RECORD's state, not a command form
      expect(last_response.body).not_to include("<form")
    end

    it "the record's own detail page (bare/JSON) still wins over a command sharing its name" do
      register_named("Close")

      get "/Banking/Customer/Close"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      expect(JSON.parse(last_response.body)["id"]).to eq("Close")
    end

    it "the record's own detail page still wins over a query sharing its name" do
      register_named("Suspended") # "Suspended" is also Customer's own query name

      get "/Banking/Customer/Suspended.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("status: active")
      expect(last_response.body).not_to include("<h2>Results")
    end

    it "does not disturb submitting the command for a DIFFERENT (non-colliding) record" do
      register_named("Close")
      register_ada # id "c1", no collision

      post "/Banking/Customer/Close.html", "to" => "c1"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c1.html")

      get "/Banking/Customer/c1.html"
      expect(last_response.body).to include("status: closed")
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

  # H12 — CustomerNumber's own `pattern:` is `[^ \t\n\r]` (just "no
  # whitespace"), so a dot is a perfectly legal identity value — an email
  # `identified_by { email.address }` or any decimal-ish reference would hit
  # this same way. `reference.value=c.1` is the audit's own live repro
  # (docs/audits/2026-08-10-main-bug-audit.md, H12).
  describe "a record id containing a dot" do
    def register_dotted
      post "/Banking/Customer/Register.html", "reference.value" => "c.1", "name.given" => "Ada",
                                                "name.family" => "Lovelace", "email.address" => "ada@example.com"
    end

    it "redirects to the dotted id's own detail page, not a truncated one" do
      register_dotted
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/c.1.html")
    end

    it "the detail page (.html) resolves the full id, not just the part before the first dot" do
      register_dotted
      get "/Banking/Customer/c.1.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("c.1")
    end

    it "the bare/JSON path resolves the full id" do
      register_dotted
      get "/Banking/Customer/c.1"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      expect(JSON.parse(last_response.body)["id"]).to eq("c.1")
    end

    it "an explicit .json request resolves the full id" do
      register_dotted
      get "/Banking/Customer/c.1.json"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq("c.1")
    end

    it "the index page links to the dotted id's own (unambiguous) detail page" do
      register_dotted
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("/Banking/Customer/c.1.html")
    end
  end

  # L12 — the id is HTML-escaped everywhere it's rendered, but a raw `&`,
  # `+`, `?`, or `#` in an href/query-string position still corrupts the
  # link (a stray `&` smuggles a second query parameter, `#` truncates the
  # path at a fragment, etc). CustomerNumber's pattern permits all four.
  describe "a record id containing URL-syntax characters" do
    MALICIOUS_ID = "a&b+c?d#e"

    def register_malicious
      post "/Banking/Customer/Register.html", "reference.value" => MALICIOUS_ID, "name.given" => "Ada",
                                                "name.family" => "Lovelace", "email.address" => "ada@example.com"
    end

    # Rack::Test's own `get(path)` parses `path` as a URI string BEFORE it
    # ever reaches the app — a raw "?"/"#" in it is parsed as Rack::Test's
    # OWN query/fragment separator, not delivered to us at all, and a
    # percent-encoded path is left percent-ENCODED in PATH_INFO instead of
    # decoded. Neither matches a real deployment: every real Rack server
    # decodes percent-escapes into PATH_INFO before the app ever sees it
    # (that decode step is what a browser navigating our own rendered href
    # actually triggers). Setting PATH_INFO directly bypasses Rack::Test's
    # URI parsing and hands the app exactly what production would.
    def get_with_raw_path_info(path)
      get "/", {}, "PATH_INFO" => path
    end

    it "percent-encodes the id in the redirect Location after create" do
      register_malicious
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to eq("/Banking/Customer/#{URI.encode_www_form_component(MALICIOUS_ID)}.html")
    end

    it "the index page's own link to the record is percent-encoded in the href, and still HTML-escaped as link text" do
      register_malicious
      get "/Banking/Customer.html"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("href=\"/Banking/Customer/#{URI.encode_www_form_component(MALICIOUS_ID)}.html\"")
      # link text is the raw id, HTML-escaped (not percent-encoded) —
      # readable, and the & doesn't get interpreted as an entity start
      expect(last_response.body).to include(Hecks::Forms::Escape.html(MALICIOUS_ID))
      # the raw id must never appear unescaped/unencoded
      expect(last_response.body).not_to include(%(>#{MALICIOUS_ID}<))
    end

    it "resolves via the id a browser decodes back out of the percent-encoded href it was linked with" do
      register_malicious
      get_with_raw_path_info("/Banking/Customer/#{MALICIOUS_ID}.html")
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(Hecks::Forms::Escape.html(MALICIOUS_ID))
    end

    it "percent-encodes the id in a record's own command links (?to=)" do
      register_malicious
      get_with_raw_path_info("/Banking/Customer/#{MALICIOUS_ID}.html")
      expect(last_response.body).to include("?to=#{URI.encode_www_form_component(MALICIOUS_ID)}")
    end
  end

  it "refuses a chapter this app does not expose" do
    get "/Deploy/Anything.html"
    expect(last_response.status).to eq(404)
  end

  it "explicitly refuses entity command URLs until the forms router can address them" do
    post "/Banking/SafeDepositBox/Visit/Annotate.html"

    expect(last_response.status).to eq(404)
    expect(last_response.body).to include("entity command routes are not supported")
    expect(last_response.body).to include("to.aggregate and to.entity")
  end
end
