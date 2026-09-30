require "spec_helper"
require "hecks/chapters"

# `attaches` brings a chapter the gem carries (the language, Expression, Tenancy, Deploy,
# QualityControl) into a domain by name (ADR 0080, section 4). Like `uses_framework`, the attached
# chapter is a bounded context, and the consumer's sibling hecksagon for it is the
# anti-corruption layer.
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

  # QualityControl ships its ports and adapters beside its bluebook, so every hecksagon that
  # attaches it (the Hecks chapter, the QA ledger) gets the same contract.
  describe "a chapter that ships its ports and adapters" do
    let(:registry) { attach("QualityControl") }

    it "declares the chapter's ports on its aggregates" do
      quality_control = registry.bluebook("QualityControl")

      expect(quality_control.aggregate("Ticket").port("IssueTracker")).not_to be_nil
      expect(quality_control.aggregate("Clearance").port("CI")).not_to be_nil
    end

    it "loads the adapters that bind them, one per port" do
      bound = registry.adapters.values.to_h { |adapter| [adapter.name, adapter.port] }

      expect(bound).to include("GithubIssues" => "IssueTracker", "GithubChecks" => "CI",
                               "GitPr" => "GitPr", "Agent" => "Agent")
    end

    it "loads nothing twice when a second hecksagon attaches the chapter" do
      registry_with do
        declare_console
        Hecks::Chapters.load!("QualityControl")

        expect(Hecks::Chapters.load!("QualityControl")).to be_nil
      end
    end

    it "leaves a chapter with no ports file or adapters as it was" do
      expect(attach("Deploy").adapters.keys).not_to include("GithubIssues")
    end
  end

  it "offers only the language's Translation chapter, never the grammar's" do
    paths = Hecks::Chapters.index.fetch("Translation")

    expect(paths).to all(include("/language/translation/"))
  end
end
