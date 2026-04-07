require "spec_helper"
require "hecks/binding"

RSpec.describe Hecks::Binding::RegistriesChapter do
  subject(:domain) { Hecks::Binding.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes registry aggregates" do
    expect(names).to include("DomainRegistry", "AdapterRegistry", "ExtensionRegistry",
                             "CapabilityRegistry", "TargetRegistry")
  end

  it "DomainRegistry has Register and Lookup commands" do
    agg = domain.aggregates.find { |a| a.name == "DomainRegistry" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Register", "Lookup")
  end

  it "ThreadContext has SetActor and SetTenant commands" do
    agg = domain.aggregates.find { |a| a.name == "ThreadContext" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("SetActor", "SetTenant")
  end

  it "contributes at least 10 registry aggregates" do
    registry_names = %w[DomainRegistry AdapterRegistry ExtensionRegistry CapabilityRegistry
                        GrammarRegistry TargetRegistry ValidationRegistry DumpFormatRegistry
                        ThreadContext CrossDomainRegistry]
    present = registry_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end
end
