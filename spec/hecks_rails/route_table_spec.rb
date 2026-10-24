require "spec_helper"
require_relative "../../packages/hecks-rails/lib/hecks/rails/route_table"

# The routes hecks-rails draws for a chapter, worked out with no Rails loaded (ADR 0121): a POST per
# command (creating ones on the collection), a GET per query, and a Site Route row's path winning.
RSpec.describe Hecks::Rails::RouteTable do
  # Banking's declarations, loaded without binding an adapter or opening a store.
  def banking_registry
    @banking_registry ||= Hecks.describe(InMemoryDomain::BANKING_BLUEBOOK_DIR, environment: nil).registry
  end

  # A stand-in chapter holding one `Route` value object with the given member rows.
  def route_chapter(rows)
    route = Struct.new(:hecks_name, :rows) { def members = rows }.new("Route", rows)
    Struct.new(:name, :aggregates).new("Routes", [Struct.new(:value_objects).new([route])])
  end

  def table(rows = [])
    registry = Struct.new(:bluebooks).new(banking_registry.bluebooks.merge("Routes" => route_chapter(rows)))
    described_class.new(registry, banking_registry.bluebook("Banking"))
  end

  def accounts(rows = []) = table(rows).resources.find { |resource| resource.name == "accounts" }

  def route(action, rows = []) = accounts(rows).routes.find { |candidate| candidate.action == action }

  it "draws a creating command as a POST on the collection" do
    expect(route("open").to_h.slice(:http_method, :on, :segment)).to eq(http_method: :post, on: :collection, segment: "open")
  end

  it "draws any other command as a POST on the member" do
    expect(route("freeze_account").to_h.slice(:http_method, :on)).to eq(http_method: :post, on: :member)
  end

  it "draws a query as a GET on the collection, under an action of its own" do
    expect(route("open_query").to_h.slice(:http_method, :on, :segment)).to eq(http_method: :get, on: :collection, segment: "open")
  end

  it "pluralizes the resource the way the model's route key is" do
    expect(table.resources.map(&:name)).to include("safe_deposit_boxes", "atm_cards")
  end

  it "takes a Site Route row's path and method for the verb it names" do
    row = { source: "command:Banking.Account.FreezeAccount", path: "/freeze/:id", methods: "POST" }
    expect(route("freeze_account", [row]).to_h.slice(:path, :http_method, :on))
      .to eq(path: "/freeze/:id", http_method: :post, on: nil)
  end

  it "derives the route of a verb whose Route row gives no path" do
    row = { source: "command:Banking.Account.FreezeAccount" }
    expect(route("freeze_account", [row]).on).to eq(:member)
  end
end
