require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/rails_app_files"

# The `:rails_app` projection (ADR 0121) and the writer `launch.project_rails` runs: a thin model and
# a controller per aggregate and a routes file, with every file an app already has left alone.
RSpec.describe Hecks::Projections::RailsApp do
  # Banking's declarations, loaded without binding an adapter or opening a store.
  def banking
    @banking ||= Hecks.describe(InMemoryDomain::BANKING_BLUEBOOK_DIR, environment: nil).registry.bluebook("Banking")
  end

  def files = Hecks::Projector.call(:rails_app, bluebook: banking)

  it "writes a model, named as Rails names its file's constant, for each aggregate" do
    expect(files["app/models/atm_card.rb"]).to include(%(class AtmCard < Hecks::Rails::Model\n  aggregate "Banking.ATMCard"))
  end

  it "writes a controller that drives the aggregate's model" do
    expect(files["app/controllers/safe_deposit_boxes_controller.rb"]).to include("drives SafeDepositBox")
  end

  it "writes a routes file that draws the chapter" do
    expect(files["config/routes.rb"]).to include(%(hecks_routes "banking"))
  end

  it "draws every chapter the app names in one routes file" do
    routes = Hecks::Projector.call(:rails_app, bluebook: banking, options: { route_chapters: %w[Banking Ledger] })
    expect(routes["config/routes.rb"]).to include(%(hecks_routes "ledger"))
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
      expect(report).to include("wrote app/models/order.rb", "kept config/routes.rb")
      expect(routes).to eq("# the app's own\n")
    end

    it "refuses an app with no bluebook/" do
      Dir.mktmpdir do |root|
        expect { described_class.new(root).call }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no bluebook/)
      end
    end
  end
end
