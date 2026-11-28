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
    @rows = Hecks::Adapters::KeptRows.from_registry(@registry)
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

  context "when a launcher from another repository boots the domain" do
    let(:env) { { "HECKS_LAUNCHER" => File.join(@yard, "exe/switchyard") } }

    around do |example|
      Dir.mktmpdir("kept-yard") do |yard|
        @yard = yard
        FileUtils.mkdir_p([File.join(yard, ".git"), File.join(yard, "exe"), File.join(yard, "lib/hecks/hecks")])
        example.run
      end
    end

    def yard_opt_in
      File.write(File.join(@yard, described_class::OVERLAY), %(Tickets::Work.persisted_by("SqlitePersistence")\n))
    end

    it "names its own launcher and repository in the refusal", :aggregate_failures do
      yard_opt_in
      command = "#{@yard}/exe/switchyard LocalOverlay.write! root.value=#{@yard} copy.value=main"
      expect(refusal("Epic", env: env)).to include("refused: Tickets::Epic is kept", command)
    end

    it "judges the launcher's repository, not the checkout the command works on" do
      opt_in
      expect(refusal("Epic", env: env)).to be_nil
    end
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

  it "names a kept aggregate in the warning for a saga that starts on it, once the domain keeps records" do
    allow(@registry).to receive_messages(memory_only?: false, kept_rows: [{ domain: "Hecks", aggregate: "PublishingRun" }])

    expect { @registry.verify! }.to output(/PublishingRun is on the cross-call kept list/).to_stderr
  end

  it "refuses a copy that is neither main nor train" do
    adapter = Hecks::Adapters::LocalOverlaying.new(aggregate: @registry.bluebook("Hecks").aggregate("LocalOverlay"))
    expect { adapter.lay(root: { value: @root }, copy: { value: "x" }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not one of main, train/)
  end
end
