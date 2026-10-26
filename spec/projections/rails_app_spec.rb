require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/rails_app_files"

# The `:rails_app` projection and the writer `launch.project_rails` runs: a controller per
# aggregate and a routes file, with every file an app already has left alone.
RSpec.describe Hecks::Projections::RailsApp do
  # Banking's declarations, loaded without binding an adapter or opening a store.
  def banking
    @banking ||= Hecks.describe(InMemoryDomain::BANKING_BLUEBOOK_DIR, environment: nil).registry.bluebook("Banking")
  end

  def files = Hecks::Projector.call(:rails_app, bluebook: banking)

  # An aggregate that takes a command, as far as the projection reads one.
  def double_aggregate(name) = instance_double(Hecks::Bluebook::Aggregate, hecks_name: name, commands: [:any])

  it "writes a controller, named for its resource, for each aggregate" do
    controller = files["app/controllers/safe_deposit_boxes_controller.rb"]
    expect(controller).to include("class SafeDepositBoxesController < ApplicationController")
  end

  it "writes no model, since hecks-rails generates one per aggregate" do
    expect(files.keys.grep(%r{app/models})).to be_empty
  end

  it "draws a resource per aggregate in the routes file" do
    expect(files["config/routes.rb"]).to include("  resources :atm_cards\n", "  resources :accounts\n")
  end

  describe "the root route" do
    let(:chapter) { Struct.new(:aggregates).new([double_aggregate("Order"), double_aggregate("Basket")]) }

    def root_for(rows)
      allow(Hecks::Projections::Site::Table).to receive(:rows_of).and_return(rows)
      described_class.routes([chapter])
    end

    it "opens the app on the first aggregate's list when no App row names one" do
      expect(root_for([])).to include("root to: \"orders#index\"")
    end

    it "opens the app on the aggregate the App row names as home" do
      expect(root_for([{ home: "Basket" }])).to include("root to: \"baskets#index\"")
    end

    it "falls back to the first aggregate when the App row names one the chapter lacks" do
      expect(root_for([{ home: "Nowhere" }])).to include("root to: \"orders#index\"")
    end
  end

  it "names nothing of the runtime" do
    expect(files.values.join).not_to include("Runtime")
  end

  describe Hecks::Adapters::RailsAppFiles do
    # A Rails app directory holding the pizzas domain in its bluebook/ and a routes file of its own.
    def app_with_pizzas(root)
      FileUtils.cp_r(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook"), File.join(root, "bluebook"))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/routes.rb"), "# the app's own\n")
      root
    end

    # Writes the projection into a fresh app and answers the report and the routes file after it.
    def project_into_fresh_app
      Dir.mktmpdir do |root|
        report = described_class.new(app_with_pizzas(root)).call
        [report, File.read(File.join(root, "config/routes.rb"))]
      end
    end

    it "writes the app's files and keeps one it already has", :aggregate_failures do
      report, routes = project_into_fresh_app
      expect(report).to include("wrote app/controllers/orders_controller.rb", "kept config/routes.rb")
      expect(routes).to eq("# the app's own\n")
    end

    it "refuses an app with no bluebook/" do
      Dir.mktmpdir do |root|
        expect { described_class.new(root).call }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no bluebook/)
      end
    end
  end
end
