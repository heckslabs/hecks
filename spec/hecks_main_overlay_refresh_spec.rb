require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/main_overlay"

# A boarding keeps the owner's checkout overlay in step with the KeptAggregate rows, so a row
# added to the list (the Sprint) reaches the live store instead of waiting for a hand write.
RSpec.describe "a boarding refreshes the owner's main overlay" do
  before(:all) { @rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  let(:root) { Dir.mktmpdir("main-overlay") }
  let(:file) { File.join(root, Hecks::Adapters::MainIntegration::LocalOverlay::PATH) }
  let(:overlay) { Hecks::Adapters::MainIntegration::MainOverlay.new(root, @rows) }

  before { FileUtils.mkdir_p(File.join(root, ".git")) }

  after { FileUtils.remove_entry(root) }

  def lag
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "Hecks.hecksagon \"Tickets\" do\n  Tickets::Work.persisted_by(\"SqlitePersistence\")\nend\n")
  end

  it "binds the Tickets Sprint in an overlay that lags the rows" do
    lag
    overlay.refresh
    expect(File.read(file)).to include("Tickets::Sprint.persisted_by(\"SqlitePersistence\")")
  end

  it "creates no overlay in a checkout that has none", :aggregate_failures do
    expect(overlay.refresh).to include("no overlay")
    expect(File.exist?(file)).to be(false)
  end

  it "leaves a linked worktree alone", :aggregate_failures do
    FileUtils.rm_rf(File.join(root, ".git"))
    File.write(File.join(root, ".git"), "gitdir: elsewhere")
    lag
    expect(overlay.refresh).to include("worktree")
    expect(File.read(file)).not_to include("Sprint")
  end

  it "says a current overlay is current" do
    lag
    overlay.refresh
    expect(overlay.refresh).to include("current")
  end

  it "reports and never raises when no row was read", :aggregate_failures do
    lag
    said = Hecks::Adapters::MainIntegration::MainOverlay.new(root, []).refresh
    expect(said).to include("kept as it is")
    expect(File.read(file)).not_to include("Sprint")
  end
end
