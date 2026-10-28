require "spec_helper"
require "hecks/bluebook/model_check"

# A translates has to listen to a context its hecksagon acknowledges, and contexts that depend on
# each other in a cycle are reported across the whole corpus.
RSpec.describe Hecks::Bluebook::ModelCheck::ContextChecks do
  DECLARE_CHK_CONTEXT = lambda do |name, aggregate, fact|
    Hecks.bluebook name do
      aggregate aggregate do
        identified_by :id
        attribute :id, Id

        value_object "Id" do
          attribute :value, String
          invariant("an id is present") { !value.to_s.empty? }
        end

        command "Fire" do
          goal "emit a fact"
          attribute :id, Id
          sets :id
          emits fact
        end
      end
    end
  end

  WIRE_CHK_LOCAL = lambda do
    Hecks.hecksagon "ChkLocal" do
      ChkLocal::Echo.persisted_by("Memory")
      translates("EchoOnThingFired") do
        on Thing::ThingFired
        trigger Echo::Fire
      end
    end
  end

  OWNERS = { "Thing" => ["ChkUpstream"], "Echo" => ["ChkLocal"] }.freeze

  def registry
    @registry ||= Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        DECLARE_CHK_CONTEXT.call("ChkUpstream", "Thing", "ThingFired")
        DECLARE_CHK_CONTEXT.call("ChkLocal", "Echo", "EchoFired")
        WIRE_CHK_LOCAL.call
      end
    end
  end

  def kinds(hecksagon: registry.hecksagon("ChkLocal"), owners: OWNERS)
    Hecks::Bluebook::ModelCheck.call(registry.bluebook("ChkLocal"), hecksagon: hecksagon, aggregate_owners: owners)
                               .map(&:kind)
  end

  def wiring(**facets)
    Hecks::Bluebook::Hecksagon.new(domain: "ChkLocal", translates: ["EchoOnThingFired"], **facets)
  end

  describe "a translates source" do
    it "is flagged when the hecksagon neither attaches nor subscribes to its context" do
      expect(kinds).to include(:unacknowledged_source)
    end

    it "is accepted once the hecksagon subscribes to an event of that context" do
      expect(kinds(hecksagon: wiring(subscriptions: ["ChkUpstream.ThingFired"]))).not_to include(:unacknowledged_source)
    end

    it "is accepted once the hecksagon attaches that context" do
      attached = wiring(attachments: [Hecks::Bluebook::Attachment.new(name: "ChkUpstream", source: :gem)])

      expect(kinds(hecksagon: attached)).not_to include(:unacknowledged_source)
    end

    it "is accepted when any context that declares the aggregate is acknowledged" do
      owners = { "Thing" => %w[ChkUpstream ChkOther] }

      expect(kinds(hecksagon: wiring(subscriptions: ["ChkOther.Seen"]), owners: owners))
        .not_to include(:unacknowledged_source)
    end

    it "is not checked without the corpus's owners, or when the bluebook owns the aggregate itself", :aggregate_failures do
      expect(kinds(owners: nil)).not_to include(:unacknowledged_source)
      expect(kinds(owners: { "Thing" => ["ChkLocal"] })).not_to include(:unacknowledged_source)
    end
  end

  describe "context cycles" do
    def edge(from, to, kind) = { from: from, to: to, kind: kind }

    def cycles(*edges) = Hecks::Bluebook::ModelCheck.context_cycle_findings(edges)

    it "reports two contexts that depend on each other as one warning" do
      found = cycles(edge("A", "B", "acl"), edge("B", "A", "customer_supplier"))

      expect(found.map { |f| [f.kind, f.severity, f.subject] }).to eq([[:context_cycle, :warning, "A <-> B"]])
    end

    it "reports a longer ring once, naming every context in it" do
      found = cycles(edge("A", "B", "acl"), edge("B", "C", "acl"), edge("C", "A", "acl"))

      expect(found.map(&:subject)).to eq(["A <-> B <-> C"])
    end

    it "leaves a one-way dependency alone" do
      expect(cycles(edge("A", "B", "acl"), edge("B", "C", "customer_supplier"))).to be_empty
    end

    it "leaves a mutual shared kernel and a subscription alone, since neither couples contexts at run time" do
      found = cycles(edge("A", "B", "shared_kernel"), edge("B", "A", "shared_kernel"), edge("A", "B", "subscription"))

      expect(found).to be_empty
    end
  end
end
