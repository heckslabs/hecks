require_relative "../spec_helper"

# The fixture app driving examples/banking end to end: a clerk opens an account, a compliance
# officer freezes it, and a second freeze is refused with the lifecycle rule's own words.
RSpec.describe "An account, through the fixture Rails app", type: :request do
  let(:clerk) { fresh("clerk-") }
  let(:officer) { fresh("officer-") }
  let(:customer) { fresh("c") }
  let(:number) { fresh("a") }

  before do
    grant(clerk, "Branch clerk")
    grant(officer, "Compliance officer")
    register_customer(customer)
  end

  def open_account(actor = clerk)
    post "/accounts/open", params:  { "customer" => customer, "number.value" => number, "kind.name" => "current",
                                      "daily_limit.cents" => "1000" },
                           headers: { "X-Actor" => actor }.compact
  end

  def freeze_account(actor = officer)
    post "/accounts/#{number}/freeze_account", headers: { "X-Actor" => actor }
  end

  it "opens an account and redirects to it" do
    open_account
    expect(response).to redirect_to("/accounts/#{number}")
  end

  it "freezes an open account" do
    open_account
    freeze_account
    expect(Account.find(number).status).to eq("frozen")
  end

  it "answers 422 with the rule's wording when freezing is refused", :aggregate_failures do
    open_account
    freeze_account
    freeze_account
    expect(response).to have_http_status(422)
    expect(response).to be_refused_with(%(status is "frozen", and FreezeAccount moves it only from "open"))
  end

  it "refuses a freeze by an actor Governance has not granted the role" do
    open_account
    freeze_account(clerk)
    expect(response).to be_refused_with("role: Compliance officer")
  end

  it "refuses an anonymous request to open an account" do
    open_account(nil)
    expect(response).to be_refused_with("Open refused")
  end

  it "shows the account with the verb's form" do
    open_account
    get "/accounts/#{number}"
    expect(response.body).to include(%(action="/accounts/#{number}/freeze_account"))
  end

  it "answers a query on the collection with GET" do
    get "/accounts/open"
    expect(response.parsed_body).to be_an(Array)
  end
end
