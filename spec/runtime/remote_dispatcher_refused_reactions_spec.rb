require "spec_helper"

# **Refused reactions cross the wire** — the newest step's ride the dispatch result, so the
# launcher answers and `--wait` exit status match a local run. The transport is a fake; only
# the wire shape is real.
RSpec.describe Hecks::Runtime::RemoteDispatcher do
  let(:remote)    { Class.new { include Hecks::Ports::Persistence::RemoteRuntime } }
  let(:registry)  { boot_in_memory.registry }
  let(:fake_client) { instance_double(Hecks::Adapters::Lambda::Client) }

  def verb = "Pizzas::Order.CreatePizza"

  def stub_transport(response)
    allow(fake_client).to receive(:dispatch).and_return(response)
    allow(Hecks::Adapters::Lambda::Client).to receive(:new).and_return(fake_client)
    allow(registry).to receive_messages(root: "/x/task")
  end

  def dispatcher_answering(response)
    stub_transport(response)
    dispatcher = described_class.new(registry)
    allow(Hecks::Ports::Persistence::BindingPolicy).to receive(:resolve).and_return(double(adapter: :lambda))
    allow(registry).to receive_messages(adapter_class: remote)
    dispatcher
  end

  def response(reactions_per_step)
    { "refusals" => [], "events" => [],
      "mutations" => [[{ "aggregate" => "Pizzas::Order", "id" => "r1", "state" => { "id" => "r1", "status" => "available" } }]],
      "reactions_per_step" => reactions_per_step }
  end

  # The dispatch result of a remote run whose host reported these reactions, one list per step.
  def result_for(reactions_per_step) = dispatcher_answering(response(reactions_per_step)).dispatch_flat(verb, {})

  def delivered_reaction(policy, trigger) = { "policy" => policy, "trigger" => trigger, "delivered" => true }

  def refused_reaction(policy, trigger, reason)
    { "policy" => policy, "trigger" => trigger, "delivered" => false, "reason" => reason }
  end

  def match_reaction
    { "policy" => "RecordTheMatch", "on" => "Answered", "trigger" => "D::Cmp.Match", "delivered" => true }
  end

  def drift_reaction
    refused_reaction("RecordTheDrift", "D::Cmp.Drift", "Drift refused — the templates differ").merge("on" => "Answered")
  end

  def accept_reaction
    refused_reaction("Accept", "D::Run.Accept", "Accept refused — the working tree is clean").merge("on" => "Examined")
  end

  it "reports only the newest step's refused reactions, not the replayed history's" do
    old     = refused_reaction("Old", "D::Old", "no")
    refused = refused_reaction("Gate", "D::Admit", "Admit refused — a given").merge("on" => "Ran")
    result  = result_for([[old], [delivered_reaction("Fine", "D::Fine"), refused]])

    expect(result.refused_reactions)
      .to eq([{ policy: "Gate", trigger: "D::Admit", reason: "Admit refused — a given" }])
  end

  it "reports none when every reaction was delivered", :aggregate_failures do
    expect(result_for([[delivered_reaction("Fine", "D::Fine")]]).refused_reactions).to eq([])
  end

  it "reports none when the host sent no per-step log" do
    result = dispatcher_answering(response([]).except("reactions_per_step")).dispatch_flat(verb, {})

    expect(result.refused_reactions).to eq([])
  end

  it "lets the launcher name the refusal for a remote result" do
    result = result_for([[refused_reaction("Gate", "D::Admit", "no")]])

    expect(Hecks::Doors::CliRunner.refused_answer(result))
      .to eq(refused_reactions: [{ policy: "Gate", trigger: "D::Admit", reason: "no" }])
  end

  describe "which refusals block the run" do
    it "does not count a given-gated pair's declined half, but counts a refusal with no alternative", :aggregate_failures do
      result = result_for([[match_reaction, drift_reaction, accept_reaction]])

      expect(result.refused_reactions.map { |r| r[:trigger] }).to eq(%w[D::Cmp.Drift D::Run.Accept])
      expect(result.blocking_reactions.map { |r| r[:trigger] }).to eq(["D::Run.Accept"])
    end

    it "exits 1 under --wait for a remote result with a blocking refusal, 0 for a benign one", :aggregate_failures do
      blocked = result_for([[accept_reaction]])
      benign  = result_for([[match_reaction, drift_reaction]])

      expect(Hecks::Doors::CliRunner.blocked?(blocked)).to be(true)
      expect(Hecks::Doors::CliRunner.blocked?(benign)).to be(false)
    end
  end
end
