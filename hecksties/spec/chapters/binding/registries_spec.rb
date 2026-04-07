require "spec_helper"
require "hecks/chapters/binding"

RSpec.describe Hecks::Chapters::Binding::RegistriesChapter do
  subject(:domain) { Hecks::Chapters::Binding.definition }

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

  it "includes registry method modules" do
    expect(names).to include(
      "AdapterRegistryMethods", "CapabilityRegistryMethods", "DomainRegistryMethods",
      "ExtensionRegistryMethods", "TargetRegistryMethods", "ValidationRegistryMethods",
      "DumpFormatRegistryMethods", "GrammarRegistryMethods"
    )
  end

  it "includes GrammarDescriptor" do
    agg = domain.aggregates.find { |a| a.name == "GrammarDescriptor" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Configure")
  end

  it "includes CrossDomainMethods" do
    agg = domain.aggregates.find { |a| a.name == "CrossDomainMethods" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("RegisterQuery")
  end

  it "includes ThreadContextMethods" do
    agg = domain.aggregates.find { |a| a.name == "ThreadContextMethods" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("SetContext")
  end

  it "contributes at least 21 registry aggregates total" do
    expect(names.count { |n| n =~ /Registry|Methods|Descriptor|Context|CrossDomain/ }).to be >= 21
  end
end
