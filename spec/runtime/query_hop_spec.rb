require "spec_helper"

# A dotted where hops through a reference, end to end on Memory: single-hop, multi-hop and
# self-referential.
RSpec.describe "cross-aggregate query filtering" do
  HOP_CHAIN = File.join(InMemoryDomain::ROOT, "spec/fixtures/hop_chain.bluebook")

  def bind_memory
    Hecks.hecksagon("HopChain") do
      HopChain::Client.persisted_by("Memory")
      HopChain::Engagement.persisted_by("Memory")
      HopChain::Proposal.persisted_by("Memory")
      HopChain::Node.persisted_by("Memory")
    end
  end

  def load_memory_stack
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  def boot_hop_chain
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_memory_stack
      Kernel.load(HOP_CHAIN)
      bind_memory
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_hop_chain }

  before do
    runtime.dispatch_flat("HopChain::Client.Register", name: { value: "Acme" })
    runtime.dispatch_flat("HopChain::Client.Register", name: { value: "Zombie Corp" })
    runtime.dispatch_flat("HopChain::Client.Churn", name: { value: "Zombie Corp" })

    runtime.dispatch_flat("HopChain::Engagement.Start", client: "Acme", reference: { value: "e-1" })
    runtime.dispatch_flat("HopChain::Engagement.Demo", reference: { value: "e-1" })
    runtime.dispatch_flat("HopChain::Engagement.Start", client: "Zombie Corp", reference: { value: "e-2" })
    runtime.dispatch_flat("HopChain::Engagement.Demo", reference: { value: "e-2" })

    runtime.dispatch_flat("HopChain::Proposal.Draft", engagement: "e-1", number: { value: "P-1" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-1" })
    runtime.dispatch_flat("HopChain::Proposal.Draft", engagement: "e-2", number: { value: "P-2" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-2" })
    # No engagement: the command's `reference_to` is optional so this state is reachable.
    runtime.dispatch_flat("HopChain::Proposal.Draft", number: { value: "P-3" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-3" })
  end

  it "infers a hop comparison argument from the field it is compared with" do
    node = runtime.registry.bluebook("HopChain").aggregate("Node")
    label = node.query("GrandparentLabelled").attribute(:label)

    expect([label.name, label.type.to_s]).to eq([:label, "Label"])
  end

  def ids(query, **args) = runtime.query(query, **args).map { |r| r[:id] }

  def plant_three_generations
    runtime.dispatch_flat("HopChain::Node.Plant", label: { value: "root" })
    runtime.dispatch_flat("HopChain::Node.Plant", parent: "root", label: { value: "child" })
    runtime.dispatch_flat("HopChain::Node.Plant", parent: "child", label: { value: "grandchild" })
  end

  it "answers a single hop" do
    expect(ids("HopChain::Engagement.WithActiveClient")).to eq(%w[e-1])
  end

  it "answers a two-hop chain" do
    expect(ids("HopChain::Proposal.AwaitingReplyFromActiveClients")).to eq(%w[P-1])
  end

  it "combines a hop with a local clause, an order, and a limit" do
    expect(ids("HopChain::Proposal.PricedAboveViaEngagement")).to eq(%w[P-1])
  end

  # "Not from an active client" means "points at a churned client", so P-3 (no engagement)
  # and P-1 (active client) are both excluded; a nil reference must not satisfy `ne`.
  it "never lets a nil reference satisfy a negated hop clause" do
    expect(ids("HopChain::Proposal.SentButNotFromActiveClients")).to eq(%w[P-2])
  end

  it "the nil-reference proposal matches no hop clause at all, positive or negated", :aggregate_failures do
    expect(ids("HopChain::Proposal.AwaitingReplyFromActiveClients")).not_to include("P-3")
    expect(ids("HopChain::Proposal.SentButNotFromActiveClients")).not_to include("P-3")
  end

  # The same aggregate type may appear twice in one chain without being refused as a cycle.
  it "answers a hop chain that revisits the same aggregate type" do
    plant_three_generations

    expect(ids("HopChain::Node.GrandparentLabelled", label: { value: "root" })).to eq(%w[grandchild])
  end

  # The native fold (Runtime::ReferenceHop) and the naive per-row reference walk must agree.
  describe "native and reference answers agree" do
    %w[
      HopChain::Engagement.WithActiveClient
      HopChain::Proposal.AwaitingReplyFromActiveClients
      HopChain::Proposal.SentButNotFromActiveClients
      HopChain::Proposal.PricedAboveViaEngagement
    ].each do |query|
      it "agree on #{query}" do
        native    = runtime.query(query).map { |r| r[:id] }.sort
        reference = runtime.reference_query(query).map { |r| r[:id] }.sort

        expect(native).to eq(reference)
      end
    end

    it "agree on the self-referential chain" do
      plant_three_generations
      args = { label: { value: "root" } }
      native    = runtime.query("HopChain::Node.GrandparentLabelled", **args).map { |r| r[:id] }.sort
      reference = runtime.reference_query("HopChain::Node.GrandparentLabelled", **args).map { |r| r[:id] }.sort

      expect(native).to eq(reference)
    end
  end
end
