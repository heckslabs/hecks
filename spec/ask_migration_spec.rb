require "spec_helper"
require "hecks/tools/model_check"

# ADR 0100's waves: a policy listed here has moved its port-naming trigger to `ask`, and a new
# `trigger Aggregate::Port::Operation` in it is refused, so the leak cannot grow back.
RSpec.describe "policies migrated to ask" do
  # Wave 1 is the policies of the developer tooling (Introspection, ModelCheckRun, Package,
  # Registry, Launch, Build and FuzzRun); each later wave adds its policies here.
  ASK_MIGRATED_POLICIES = %w[
    AnalyseWhenRequested RecordTheClean RecordTheFlag PinWhenVendored PinWhenRevendored RecordThePinning
    RecordTheRefusedPin TagWhenReleased RecordTheTag RecordTheRefusedTag WriteWhenRequested ScaffoldWhenRequested
    ProjectRailsWhenRequested ConverseWhenRequested ServeWhenRequested RecordTheLaunch RecordTheStoppedLaunch
    GenerateWhenRequested CompileWasmWhenRequested BuildParserWhenRequested BuildHostWhenRequested
    CompileBrowserWasmWhenRequested ConformWhenRequested ReplayWhenRequested AuditWhenRequested RecordTheBuild
    RecordTheFault SweepWhenRequested MutateWhenRequested MeasureWhenRequested RecordTheSweep RecordTheFinding
  ].freeze

  let(:declaration) do
    Hecks::Tools::ModelCheck.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks")).bluebook("Hecks")
  end

  def port_triggers
    declaration.policies.select { |policy| ASK_MIGRATED_POLICIES.include?(policy.name) }
               .select { |policy| Hecks::Bluebook::ModelCheck.ask_finding(declaration, policy)&.kind == :port_trigger }
               .map(&:name)
  end

  it "keeps every migrated policy free of a trigger that names a port operation" do
    expect(port_triggers).to eq([])
  end

  it "lists only policies the Hecks bluebook declares" do
    expect(ASK_MIGRATED_POLICIES - declaration.policies.map(&:name)).to eq([])
  end
end
