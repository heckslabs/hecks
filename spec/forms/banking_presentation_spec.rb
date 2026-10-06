require "spec_helper"
require "rack/test"
require "hecks/forms/banking_presentation"

RSpec.describe Hecks::Forms::BankingPresentation do
  include Rack::Test::Methods

  def app
    @app ||= described_class.app(root: InMemoryDomain::ROOT)
  end

  it "serves the index of every exposed chapter", :aggregate_failures do
    get "/"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("Banking")
  end

  it "shows the customers of the in-memory banking example" do
    get "/Banking/Customer.html"

    expect(last_response.status).to eq(200)
  end
end
