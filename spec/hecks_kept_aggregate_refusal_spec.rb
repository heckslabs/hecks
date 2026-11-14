require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/write_guard"
require "hecks/adapters/driving/ledger_stores"
require "hecks/hecks/adapters/local_overlaying"

# A checkout that has opted into persistence, but whose overlay binds a kept aggregate to Memory,
# refuses the write by the aggregate's name instead of forgetting the record by the next command.
RSpec.describe Hecks::Adapters::Driving::KeptCheck do
  before(:all) do
    @registry = boot_hecks_in_memory.registry
    @rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(@registry)
    @stores = Hecks::Adapters::Driving::LedgerStores.registry_rows(@registry)
  end

  around do |example|
    Dir.mktmpdir("kept-check") do |root|
      @root = root
      FileUtils.mkdir_p([File.join(root, ".git"), File.join(root, "lib/hecks/hecks")])
      example.run
    end
  end

  def opt_in
    File.write(File.join(@root, described_class::OVERLAY), %(Tickets::Work.persisted_by("SqlitePersistence")\n))
  end

  def refusal(aggregate, env: {})
    check = described_class.new(@rows, ->(_root) { @stores }, env)
    Hecks::Adapters::Driving::WriteGuard.kept_verdict(@root, "Tickets", aggregate: aggregate, kept: check).refusal
  end

  it "refuses a checkout whose overlay lacks Tickets::Epic, naming it and the command that writes it" do
    opt_in
    command = "LocalOverlay.write! root.value=#{@root} copy.value=main"
    expect(refusal("Epic")).to include("refused: Tickets::Epic is kept", command)
  end

  it "lets a checkout with no local overlay keep its records in Memory" do
    expect(refusal("Epic")).to be_nil
  end

  it "lets a process that asks for Memory through" do
    opt_in
    expect(refusal("Epic", env: { "HECKS_ENVIRONMENT" => "memory" })).to be_nil
  end

  it "lets an aggregate the list leaves out through" do
    opt_in
    expect(refusal("Adr")).to be_nil
  end

  it "writes the overlay the refusal names, through the port's adapter", :aggregate_failures do
    adapter = Hecks::Adapters::LocalOverlaying.new(aggregate: @registry.bluebook("Hecks").aggregate("LocalOverlay"))
    said = adapter.lay(root: { value: @root }, copy: { value: "main" })
    expect(said[:output][:value]).to eq("wrote #{File.join(@root, described_class::OVERLAY)}")
    expect(File.read(File.join(@root, described_class::OVERLAY))).to include("Tickets::Epic.persisted_by")
  end

  it "names a kept aggregate in the warning for a saga that starts on it" do
    expect { boot_hecks_in_memory }.to output(/Landing is on the dev pipeline's kept list/).to_stderr
  end

  it "refuses a copy that is neither main nor train" do
    adapter = Hecks::Adapters::LocalOverlaying.new(aggregate: @registry.bluebook("Hecks").aggregate("LocalOverlay"))
    expect { adapter.lay(root: { value: @root }, copy: { value: "x" }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not one of main, train/)
  end
end
