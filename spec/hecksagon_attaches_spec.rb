require "spec_helper"
require "hecks/framework_bluebooks"

# `attaches` brings a bluebook the gem carries (the language, Expression, Tenancy, Deploy,
# Site, QualityControl) into a domain by name (ADR 0080, section 4). Like a vendored package, the
# attached
# bluebook is a bounded context, and the consumer's sibling hecksagon for it is the
# anti-corruption layer.
RSpec.describe "a hecksagon attaching a bluebook the gem carries" do
  def registry_with(&)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      yield
    end
    registry
  end

  CONSOLE_BLUEBOOK = proc do
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

  def declare_console = Hecks.bluebook("Console", &CONSOLE_BLUEBOOK)

  def console_hexagon(name)
    Hecks.hecksagon "Console" do
      attaches name
      Console::Session.persisted_by("Memory")
    end
  end

  def sibling_hexagon(name)
    Hecks.hecksagon name do
      persisted_by "Memory"
    end
  end

  def attach(name, sibling: true)
    registry_with do
      declare_console
      console_hexagon(name)
      sibling_hexagon(name) if sibling
    end
  end

  it "loads the bluebook and records it", :aggregate_failures do
    registry = attach("Deploy")

    expect(registry.bluebook("Deploy")).not_to be_nil
    expect(registry.hecksagon("Console").member_bluebooks).to eq(["Deploy"])
    expect(registry.hecksagon("Console").to_h[:attachments]).to eq([{ name: "Deploy", source: "gem" }])
  end

  it "marks the bluebook bounded, and boots with its sibling hecksagon", :aggregate_failures do
    registry = attach("Deploy")

    expect(registry.bounded?("Deploy")).to be true
    expect { registry.verify! }.not_to raise_error
  end

  it "attaches the Site bluebook, with the closed sets a route table is read against", :aggregate_failures do
    registry = attach("Site")

    expect(registry.bluebook("Site").aggregate("Route")).not_to be_nil
    expect(registry.hecksagon("Console").to_h[:attachments]).to eq([{ name: "Site", source: "gem" }])
    expect(registry.bounded?("Site")).to be true
    expect { registry.verify! }.not_to raise_error
  end

  it "refuses boot when the attached bluebook has no sibling hecksagon" do
    registry = attach("Deploy", sibling: false)

    expect { registry.verify! }.to raise_error(Hecks::Runtime::WiringError, /attaches "Deploy".*bounded context/m)
  end

  it "refuses a name no attachable bluebook has, listing the ones that exist" do
    expect { attach("Nowhere") }.to raise_error(Hecks::Runtime::WiringError, /no bluebook of that name.*Deploy.*from: :vendor/)
  end

  # QualityControl ships its ports and adapters beside its bluebook, so every hecksagon that
  # attaches it (the Hecks bluebook, the QA ledger) gets the same contract.
  describe "a bluebook that ships its ports and adapters" do
    let(:registry) { attach("QualityControl") }

    it "declares the bluebook's ports on its aggregates", :aggregate_failures do
      quality_control = registry.bluebook("QualityControl")

      expect(quality_control.aggregate("Ticket").port("IssueTracker")).not_to be_nil
      expect(quality_control.aggregate("Clearance").port("CI")).not_to be_nil
    end

    it "loads the adapters that bind them, one per port" do
      bound = registry.adapters.values.to_h { |adapter| [adapter.name, adapter.port] }

      expect(bound).to include("GithubIssues" => "IssueTracker", "GithubChecks" => "CI",
                               "GitPr" => "GitPr", "Agent" => "Agent")
    end

    it "loads nothing twice when a second hecksagon attaches the bluebook" do
      registry_with do
        declare_console
        Hecks::FrameworkBluebooks.load!("QualityControl")

        expect(Hecks::FrameworkBluebooks.load!("QualityControl")).to be_nil
      end
    end

    it "leaves a bluebook with no ports file or adapters as it was" do
      expect(attach("Deploy").adapters.keys).not_to include("GithubIssues")
    end
  end

  it "offers only the language's Translation bluebook, never the grammar's" do
    paths = Hecks::FrameworkBluebooks.index.fetch("Translation")

    expect(paths).to all(include("/language/translation/"))
  end

  # `attaches` is the one word for a gem bluebook and for a vendored package; the two older words
  # are deprecated spellings that behave as before and warn.
  describe "attaches, from the gem or from vendor" do
    it "finds a framework member and a language bluebook through the one table" do
      expect(Hecks::FrameworkBluebooks.table.keys).to include("Governance", "Identity", "Deploy", "Site", "Tenancy")
    end

    it "records each attachment with its source" do
      registry = registry_with { Hecks.hecksagon("Hexed") { attaches "Governance" } }

      expect(registry.hecksagon("Hexed").attachments.map(&:to_h)).to eq([{ name: "Governance", source: "gem" }])
    end

    it "refuses a vendored name used without from:, naming the way to attach a vendored package" do
      expect { registry_with { Hecks.hecksagon("Hexed") { attaches "membership" } } }
        .to raise_error(Hecks::Runtime::WiringError, /known: .*Governance.*from: :vendor/)
    end

    it "refuses a gem name used with from: :vendor, since a vendored package is never a fallback" do
      expect { registry_with { Hecks.hecksagon("Hexed") { attaches "Governance", from: :vendor } } }
        .to raise_error(Hecks::Runtime::WiringError, /needs a registry with a root to vendor from/)
    end

    it "refuses a source other than :vendor" do
      expect { registry_with { Hecks.hecksagon("Hexed") { attaches "Governance", from: :gem } } }
        .to raise_error(Hecks::Runtime::WiringError, /`from:` takes only :vendor/)
    end

    {
      "uses_framework"           => ['uses_framework "Governance"', 'attaches "Governance"'],
      "uses_embryonaut_bluebook" => ['uses_embryonaut_bluebook "payments"', 'attaches "payments", from: :vendor']
    }.each do |word, (call, instead)|
      it "refuses #{word}, removed in 3.4.0, naming #{instead}" do
        expect { registry_with { Hecks.hecksagon("Hexed") { instance_eval(call) } } }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /`#{word}` was removed in 3\.4\.0; use `#{Regexp.escape(instead)}`/)
      end
    end

    %w[capabilities concerns annotate].each do |word|
      it "refuses #{word}, a retired word nothing reads" do
        expect { registry_with { Hecks.hecksagon("Hexed") { public_send(word, :webapp) } } }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /`#{word}` is not a hecksagon word and nothing reads it/)
      end
    end

    it "merges two hecksagon blocks' attachments without repeating one" do
      registry = registry_with do
        Hecks.hecksagon("Hexed") { attaches "Governance" }
        Hecks.hecksagon("Hexed") { attaches "Governance" }
      end

      expect(registry.hecksagon("Hexed").member_bluebooks).to eq(["Governance"])
    end
  end
end
