require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime::Setup do
  subject(:domain) { Hecks::Chapters::Runtime.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes boot and configuration aggregates" do
    expect(names).to include("BootBluebook", "BootPhase", "ConfigurationDSL",
                             "ConnectionSetup", "ConstantHoisting")
  end

  it "includes loader and extension aggregates" do
    expect(names).to include("DomainConfigBuilder", "DomainLoader",
                             "ExtensionDispatch", "LoadExtensions")
  end

  it "includes wiring aggregates" do
    expect(names).to include("PolicySetup", "PortSetup", "ReadModelSetup",
                             "RepositorySetup", "SagaSetup", "ServiceSetup",
                             "ServiceContext", "SubscriberSetup")
  end

  it "includes dispatch and check aggregates" do
    expect(names).to include("ViewSetup", "WorkflowSetup", "CommandDispatch",
                             "AuthCoverageCheck", "ReferenceCoverageCheck",
                             "Versioning")
  end

  it "DomainLoader has LoadFromFile and LoadFromGem commands" do
    agg = domain.aggregates.find { |a| a.name == "DomainLoader" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("LoadFromFile", "LoadFromGem")
  end

  it "contributes at least 22 setup aggregates" do
    setup_names = %w[BootBluebook BootPhase ConfigurationDSL ConnectionSetup
                     ConstantHoisting DomainConfigBuilder DomainLoader
                     ExtensionDispatch LoadExtensions PolicySetup PortSetup
                     ReadModelSetup RepositorySetup SagaSetup ServiceSetup
                     ServiceContext SubscriberSetup ViewSetup WorkflowSetup
                     CommandDispatch AuthCoverageCheck ReferenceCoverageCheck
                     Versioning]
    present = setup_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 22
  end
end
