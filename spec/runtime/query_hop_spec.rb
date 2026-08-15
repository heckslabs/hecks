require "spec_helper"

# A DOTTED WHERE HOPS THROUGH A REFERENCE — end to end, on Memory, the
# same fixture single-hop, multi-hop, and self-referential.
RSpec.describe "cross-aggregate query filtering" do
  HOP_CHAIN = File.join(InMemoryDomain::ROOT, "spec/fixtures/hop_chain.bluebook")

  def boot_hop_chain
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(HOP_CHAIN)
      Hecks.hecksagon("HopChain") do
        ::HopChain::Client.persisted_by("Memory")
        ::HopChain::Engagement.persisted_by("Memory")
        ::HopChain::Proposal.persisted_by("Memory")
        ::HopChain::Node.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_hop_chain }

  before do
    runtime.dispatch("HopChain::Client.Register", name: { value: "Acme" })
    runtime.dispatch("HopChain::Client.Register", name: { value: "Zombie Corp" })
    runtime.dispatch("HopChain::Client.Churn", name: { value: "Zombie Corp" })

    runtime.dispatch("HopChain::Engagement.Start", client: "Acme", reference: { value: "e-1" })
    runtime.dispatch("HopChain::Engagement.Demo", reference: { value: "e-1" })
    runtime.dispatch("HopChain::Engagement.Start", client: "Zombie Corp", reference: { value: "e-2" })
    runtime.dispatch("HopChain::Engagement.Demo", reference: { value: "e-2" })

    runtime.dispatch("HopChain::Proposal.Draft", engagement: "e-1", number: { value: "P-1" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-1" })
    runtime.dispatch("HopChain::Proposal.Draft", engagement: "e-2", number: { value: "P-2" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-2" })
    # No engagement at all — the command's own reference_to is optional
    # precisely so this state is reachable through the door.
    runtime.dispatch("HopChain::Proposal.Draft", number: { value: "P-3" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-3" })
  end

  def ids(query, **args) = runtime.query(query, **args).map { |r| r[:id] }

  it "answers a single hop" do
    expect(ids("HopChain::Engagement.WithActiveClient")).to eq(%w[e-1])
  end

  it "answers a two-hop chain" do
    expect(ids("HopChain::Proposal.AwaitingReplyFromActiveClients")).to eq(%w[P-1])
  end

  it "combines a hop with a local clause, an order, and a limit" do
    expect(ids("HopChain::Proposal.PricedAboveViaEngagement")).to eq(%w[P-1])
  end

  # THE EXISTENTIAL-NEGATION CASE — "not from an active client" must
  # mean "points at a client that is churned," never "no client at
  # all counts too." P-3 (no engagement) and P-1 (active client) both
  # have to be excluded here, for different reasons, and neither may
  # slip in through a comparator that quietly treats a missing
  # reference as satisfying `ne`.
  it "never lets a nil reference satisfy a negated hop clause" do
    expect(ids("HopChain::Proposal.SentButNotFromActiveClients")).to eq(%w[P-2])
  end

  it "the nil-reference proposal matches no hop clause at all, positive or negated" do
    expect(ids("HopChain::Proposal.AwaitingReplyFromActiveClients")).not_to include("P-3")
    expect(ids("HopChain::Proposal.SentButNotFromActiveClients")).not_to include("P-3")
  end

  # A SELF-REFERENTIAL CHAIN, TWO HOPS DEEP — proving the same
  # aggregate type can appear twice in one chain without being refused
  # as a "cycle." See spec/dsl_spec.rb for the seal-time proof that a
  # chain revisiting a type builds cleanly; this is the runtime half.
  it "answers a hop chain that revisits the same aggregate type" do
    runtime.dispatch("HopChain::Node.Plant", label: { value: "root" })
    runtime.dispatch("HopChain::Node.Plant", parent: "root", label: { value: "child" })
    runtime.dispatch("HopChain::Node.Plant", parent: "child", label: { value: "grandchild" })

    expect(ids("HopChain::Node.GrandparentLabelled", label: { value: "root" })).to eq(%w[grandchild])
  end

  # NATIVE (Runtime::ReferenceHop's fold) and REFERENCE (the naive
  # per-row walk reference_call gives the fuzzer's oracle) must answer
  # every hop query identically — the same differential proof
  # spec/fuzzing exercises generatively, pinned here by hand for the
  # specific cases above.
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
      runtime.dispatch("HopChain::Node.Plant", label: { value: "root" })
      runtime.dispatch("HopChain::Node.Plant", parent: "root", label: { value: "child" })
      runtime.dispatch("HopChain::Node.Plant", parent: "child", label: { value: "grandchild" })

      args = { label: { value: "root" } }
      native    = runtime.query("HopChain::Node.GrandparentLabelled", **args).map { |r| r[:id] }.sort
      reference = runtime.reference_query("HopChain::Node.GrandparentLabelled", **args).map { |r| r[:id] }.sort

      expect(native).to eq(reference)
    end
  end
end
