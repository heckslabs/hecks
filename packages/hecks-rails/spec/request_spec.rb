require "spec_helper"

RSpec.describe "a Rails request over the Ledger domain", type: :request do
  def app = LedgerApp

  def assign(actor, role)
    Hecks::Rails::Booted.dispatcher.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Main" }, starts_at: { value: "2026-01-01" }
    )
  rescue Hecks::Refused
    nil # the domain keeps state across examples, so a repeat grant is already held
  end

  def open_account(number, cents, actor: "teller-1")
    post "/accounts/open_account", { "number.value" => number, "owner.name" => "Ada", "balance.cents" => cents.to_s },
         { "HTTP_X_ACTOR" => actor, "HTTP_ACCEPT" => "application/json" }
  end

  def freeze_account(number, actor:)
    post "/accounts/#{number}/freeze_account", {}, { "HTTP_X_ACTOR" => actor, "HTTP_ACCEPT" => "application/json" }
  end

  def errors = JSON.parse(last_response.body).fetch("errors")

  before do
    assign("teller-1", "Teller")
    assign("officer-1", "Compliance officer")
  end

  it "opens an account and redirects to its show route" do
    open_account("A1", 0)

    expect(last_response.headers["Location"]).to end_with("/accounts/A1")
  end

  it "answers the new account's state as JSON" do
    open_account("A2", 5)
    get "/accounts/A2", {}, { "HTTP_ACCEPT" => "application/json" }

    expect(JSON.parse(last_response.body)).to include("status" => "open")
  end

  it "freezes an account when the rule holds" do
    open_account("A3", 0)
    freeze_account("A3", actor: "officer-1")

    expect(last_response.status).to eq(302)
  end

  it "refuses with 422 and the rule's own wording when the rule does not hold", :aggregate_failures do
    open_account("A4", 5)
    freeze_account("A4", actor: "officer-1")

    expect(last_response.status).to eq(422)
    expect(errors.fetch("base").first).to include("the balance is zero")
  end

  it "refuses with 403 an actor Governance has not granted the role" do
    open_account("A5", 0)
    freeze_account("A5", actor: "teller-1")

    expect(last_response.status).to eq(403)
  end

  it "refuses with 403 a request that names no actor" do
    post "/accounts/open_account", { "number.value" => "A6", "owner.name" => "Ada", "balance.cents" => "0" },
         { "HTTP_ACCEPT" => "application/json" }

    expect(last_response.status).to eq(403)
  end

  it "refuses with 404 a record that does not exist" do
    get "/accounts/nope", {}, { "HTTP_ACCEPT" => "application/json" }

    expect(last_response.status).to eq(404)
  end

  describe "a dry run" do
    def dry_run(path, params, actor: "teller-1", **headers)
      post path, params, { "HTTP_X_ACTOR" => actor, "HTTP_ACCEPT" => "application/json" }.merge(headers)
    end

    def fields(number) = { "number.value" => number, "owner.name" => "Ada", "balance.cents" => "0" }

    it "answers ok and saves nothing", :aggregate_failures do
      dry_run("/accounts/open_account?dry_run=1", fields("D1"))

      expect(JSON.parse(last_response.body)).to eq("ok" => true, "refusals" => [])
      get "/accounts/D1", {}, { "HTTP_ACCEPT" => "application/json" }
      expect(last_response.status).to eq(404)
    end

    it "answers every reason it would be refused, with 200", :aggregate_failures do
      dry_run("/accounts/open_account?dry_run=1", fields("D2").except("number.value", "owner.name"))
      refusals = JSON.parse(last_response.body).fetch("refusals")

      expect(last_response.status).to eq(200)
      expect(refusals.map { |refusal| refusal["attribute"] }).to contain_exactly("number", "owner")
    end

    it "takes the flag from the X-Dry-Run header" do
      dry_run("/accounts/open_account", fields("D3"), "HTTP_X_DRY_RUN" => "1")

      expect(JSON.parse(last_response.body)["ok"]).to be(true)
    end
  end

  describe "a refused form" do
    def html_post(path, params, actor: "teller-1") = post(path, params, { "HTTP_X_ACTOR" => actor })

    it "comes back as it was filled in, with each reason beside its field", :aggregate_failures do
      html_post("/accounts/open_account", { "owner.name" => "Ada", "balance.cents" => "5" })

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('value="Ada"')
      expect(last_response.body).to include('role="alert"')
    end

    it "carries the command's JSON Schema for a script to check against" do
      html_post("/accounts/open_account", { "owner.name" => "Ada", "balance.cents" => "5" })

      expect(last_response.body).to include('type="application/schema+json"')
    end
  end
end
