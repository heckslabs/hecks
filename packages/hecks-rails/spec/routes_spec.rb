require "spec_helper"

RSpec.describe Hecks::Rails::CommandRoutes do
  let(:routes) { described_class.for_chapter(Hecks::Rails::Booted.chapter("ledger")) }

  def row(action) = routes.find { |route| route.action == action }

  it "reads each aggregate at its show route" do
    expect(row("show")).to have_attributes(http_method: :get, scope: :member, resource: "account")
  end

  it "routes a creating command to the collection as a POST" do
    expect(row("open_account")).to have_attributes(http_method: :post, scope: :collection)
  end

  it "routes any other command to the member as a POST" do
    expect(row("freeze_account")).to have_attributes(http_method: :post, scope: :member)
  end

  it "draws the routes into the app", :aggregate_failures do
    paths = LedgerApp.routes.routes.map { |route| route.path.spec.to_s }

    expect(paths).to include("/accounts/:id(.:format)", "/accounts/open_account(.:format)")
    expect(paths).to include("/accounts/:id/freeze_account(.:format)")
  end
end
