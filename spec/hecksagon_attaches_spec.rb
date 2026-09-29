require "spec_helper"
require "hecks/chapters"

# `attaches` brings a chapter the gem carries (the language, Expression, Tenancy, Deploy) into a
# domain by name (ADR 0080, section 4). Like `uses_framework`, the attached chapter is a bounded
# context, and the consumer's sibling hecksagon for it is the anti-corruption layer.
RSpec.describe "a hecksagon attaching a chapter the gem carries" do
  def registry_with(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      block.call
    end
    registry
  end

  def declare_console
    Hecks.bluebook "Console" do
      aggregate "Session" do
        identified_by :id
        attribute :id, Id
        value_object "Id" do
          attribute :value, String
          invariant("an id is present") { !value.to_s.empty? }
        end
        command "Open" do
          goal "open a session"
          attribute :id, Id
          sets :id
          emits "Opened"
        end
      end
    end
  end

  def attach(name, sibling: true)
    registry_with do
      declare_console
      Hecks.hecksagon "Console" do
        attaches name
        Console::Session.persisted_by("Memory")
      end
      if sibling
        Hecks.hecksagon name do
          persisted_by "Memory"
        end
      end
    end
  end

  it "loads the chapter, records it, marks it bounded, and boots with its sibling hecksagon" do
    registry = attach("Deploy")

    expect(registry.bluebook("Deploy")).not_to be_nil
    expect(registry.hecksagon("Console").attached_chapters).to eq(["Deploy"])
    expect(registry.hecksagon("Console").to_h[:attached_chapters]).to eq(["Deploy"])
    expect(registry.bounded?("Deploy")).to be true
    expect { registry.verify! }.not_to raise_error
  end

  it "refuses boot when the attached chapter has no sibling hecksagon" do
    registry = attach("Deploy", sibling: false)

    expect { registry.verify! }.to raise_error(Hecks::Runtime::WiringError, /attaches "Deploy".*bounded context/m)
  end

  it "refuses a name no attachable chapter has, listing the ones that exist" do
    expect { attach("Nowhere") }.to raise_error(Hecks::Runtime::WiringError, /no attachable chapter named "Nowhere".*Deploy/)
  end

  it "offers only the language's Translation chapter, never the grammar's" do
    paths = Hecks::Chapters.index.fetch("Translation")

    expect(paths).to all(include("/language/translation/"))
  end
end
