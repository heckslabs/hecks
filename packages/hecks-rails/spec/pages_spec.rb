require "spec_helper"

RSpec.describe "the pages a Rails app has with no view files of its own", type: :request do
  def app = LedgerApp

  def html(path, actor: "teller-1") = get(path, {}, { "HTTP_X_ACTOR" => actor })

  def assign(actor, role)
    Hecks::Rails::Booted.dispatcher.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Main" }, starts_at: { value: "2026-01-01" }
    )
  rescue Hecks::Refused
    nil # the domain keeps state across examples, so a repeat grant is already held
  end

  def post_note(slug, text: "Hello")
    post "/notes/post_note", { "slug.value" => slug, "text.value" => text }, { "HTTP_X_ACTOR" => "teller-1" }
  end

  before { assign("teller-1", "Teller") }

  it "lists the records, headed with the Listing row's label", :aggregate_failures do
    post_note("first-note")
    html("/notes")

    expect(last_response.body).to include("Notes on the ledger", "first-note")
  end

  it "offers a form for each creating command" do
    html("/notes")

    expect(last_response.body).to include('action="/notes/post_note"')
  end

  it "shows only the columns the Listing row names" do
    html("/notes")

    expect(last_response.body.scan("<th>").size).to eq(1)
  end

  it "answers the list as JSON" do
    post_note("json-note")
    get "/notes", {}, { "HTTP_ACCEPT" => "application/json" }

    expect(last_response.body).to include("json-note")
  end

  it "reopens the refused command's form with the domain's reason", :aggregate_failures do
    post_note("", text: "Hello")

    expect(last_response.status).to eq(422)
    expect(last_response.body).to include('<details class="hecks-command" open>', 'role="alert"')
  end

  it "titles the pages from the App row" do
    html("/notes")

    expect(last_response.body).to include("<title>The ledger</title>")
  end

  describe "a record" do
    def open_account(number)
      post "/accounts/open_account", { "number.value" => number, "owner.name" => "Ada", "balance.cents" => "0" },
           { "HTTP_X_ACTOR" => "teller-1", "HTTP_ACCEPT" => "application/json" }
    end

    before do
      assign("officer-1", "Compliance officer")
      open_account("P1")
    end

    it "offers the commands the actor may run now" do
      html("/accounts/P1", actor: "officer-1")

      expect(last_response.body).to include('action="/accounts/P1/freeze_account"')
    end

    # Deposit and Withdraw both take a memo, so the same field would be marked on each form.
    def refused_deposit
      post "/accounts/P1/deposit", { "amount.cents" => "5", "memo.value" => "" }, { "HTTP_X_ACTOR" => "teller-1" }
    end

    it "marks a refused command's fields on its own form only" do
      refused_deposit

      expect(last_response.body.scan('class="field has-error"').size).to eq(1)
    end

    it "names the commands the domain would refuse" do
      html("/accounts/P1")

      expect(last_response.body).to include("Not available now:", "Freeze account")
    end
  end

  describe "with forgery protection on" do
    around do |example|
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    def token_in(form_action)
      html("/notes")
      last_response.body[/<form action="#{form_action}".*?name="authenticity_token" value="([^"]+)"/m, 1]
    end

    it "puts a token in each command form" do
      expect(token_in("/notes/post_note")).not_to be_nil
    end

    it "accepts the form with the token it was given" do
      token = token_in("/notes/post_note")
      post "/notes/post_note", { "slug.value" => "tokened", "text.value" => "Hi", "authenticity_token" => token },
           { "HTTP_X_ACTOR" => "teller-1" }

      expect(last_response.status).to eq(302)
    end

    it "refuses a post with no token" do
      post_note("untokened")

      expect(last_response.status).to eq(422)
    end
  end

  describe "the acting-as picker" do
    def act_as(role) = post("/hecks/actor", { "role" => role })

    def post_note_unsigned(slug = "picked") = post("/notes/post_note", { "slug.value" => slug, "text.value" => "Hi" })

    around do |example|
      Hecks::Rails.dev_actor = true
      example.run
    ensure
      Hecks::Rails.dev_actor = nil
    end

    it "signs the session in as a role, so a command passes without a header" do
      act_as("Teller")
      post_note_unsigned

      expect(last_response.status).to eq(302)
    end

    # A session signed in before the process forgot its grants, as after a restart.
    def sign_in_then_forget(role)
      act_as(role)
      Hecks::Rails::DevActor.reset!
      allow(Hecks::Rails::Booted.dispatcher).to receive(:dispatch_flat).and_call_original
    end

    def assignment(role) = hash_including(actor_id: { value: "dev-#{role.downcase}" }, role_name: { value: role })

    it "tells Governance about a session's role again when this process has not seen it" do
      sign_in_then_forget("Teller")
      post_note_unsigned("regranted")

      expect(Hecks::Rails::Booted.dispatcher).to have_received(:dispatch_flat)
        .with("Governance::RoleAssignment.Assign", assignment("Teller"))
    end

    it "does not tell Governance again for a session this process has already granted" do
      act_as("Teller")
      allow(Hecks::Rails::Booted.dispatcher).to receive(:dispatch_flat).and_call_original
      post_note_unsigned("granted-once")

      expect(Hecks::Rails::Booted.dispatcher).not_to have_received(:dispatch_flat)
        .with("Governance::RoleAssignment.Assign", anything)
    end

    it "lists the roles the domain's commands name" do
      html("/notes")

      expect(last_response.body).to include('<option value="Teller">Teller</option>')
    end

    it "signs out when no role is picked", :aggregate_failures do
      act_as("Teller")
      act_as("")
      post_note_unsigned

      expect(last_response.status).to eq(403)
    end

    it "offers nothing when the picker is off", :aggregate_failures do
      Hecks::Rails.dev_actor = false
      act_as("Teller")

      expect(last_response.status).to eq(404)
      expect(html("/notes") && last_response.body).not_to include("Acting as")
    end
  end

  describe Hecks::Rails::App do
    it "names a place in the navigation for each aggregate that takes commands", :aggregate_failures do
      labels = described_class.entries.map(&:label)

      expect(labels).to include("Accounts", "Notes on the ledger")
      expect(labels).not_to include("Desks")
    end

    it "keeps every place when the App row names a home the app lacks" do
      allow(described_class).to receive(:app_row).and_return(title: "x", home: "Nowhere")

      expect(described_class.entries.map(&:label)).to include("Accounts", "Notes on the ledger")
    end

    it "refuses a Listing column the aggregate lacks" do
      allow(described_class).to receive(:listing).and_return(columns: "slug,nope")

      expect { described_class.columns(Note) }.to raise_error(ArgumentError, /nope/)
    end
  end
end
