require "spec_helper"

# **Refused reactions cross the wire** — the newest step's ride the dispatch result, so the
# launcher answers and `--wait` exit status match a local run. The transport is a fake; only
# the wire shape is real.
RSpec.describe Hecks::Runtime::RemoteDispatcher do
  let(:verb) { "Pizzas::Order.CreatePizza" }
  let(:remote)    { Class.new { include Hecks::Ports::Persistence::RemoteRuntime } }
  let(:registry)  { boot_in_memory.registry }
  let(:fake_client) { instance_double(Hecks::Adapters::Lambda::Client) }

  def dispatcher_answering(response)
    allow(fake_client).to receive(:dispatch).and_return(response)
    allow(Hecks::Adapters::Lambda::Client).to receive(:new).and_return(fake_client)
    allow(registry).to receive_messages(root: "/x/task")
    dispatcher = described_class.new(registry)
    allow(Hecks::Ports::Persistence::BindingPolicy)
      .to receive(:resolve).and_return(double(adapter: :lambda))
    allow(registry).to receive_messages(adapter_class: remote)
    dispatcher
  end

  def response(reactions_per_step)
    { "refusals" => [], "events" => [],
      "mutations" => [[{ "aggregate" => "Pizzas::Order", "id" => "r1", "state" => { "id" => "r1", "status" => "available" } }]],
      "reactions_per_step" => reactions_per_step }
  end

  it "reports only the newest step's refused reactions, not the replayed history's" do
    old     = { "policy" => "Old", "trigger" => "D::Old", "delivered" => false, "reason" => "no" }
    refused = { "policy" => "Gate", "on" => "Ran", "trigger" => "D::Admit",
                "delivered" => false, "reason" => "Admit refused — a given" }
    ok      = { "policy" => "Fine", "trigger" => "D::Fine", "delivered" => true }
    result  = dispatcher_answering(response([[old], [ok, refused]])).dispatch_flat(verb, {})

    expect(result.refused_reactions)
      .to eq([{ policy: "Gate", trigger: "D::Admit", reason: "Admit refused — a given" }])
  end

  it "reports none when every reaction was delivered or the host sent no per-step log" do
    delivered = { "policy" => "Fine", "trigger" => "D::Fine", "delivered" => true }

    expect(dispatcher_answering(response([[delivered]])).dispatch_flat(verb, {})
             .refused_reactions).to eq([])
    expect(dispatcher_answering(response([]).except("reactions_per_step"))
             .dispatch_flat(verb, {}).refused_reactions).to eq([])
  end

  it "lets the launcher name the refusal for a remote result" do
    refused = { "policy" => "Gate", "trigger" => "D::Admit", "delivered" => false, "reason" => "no" }
    result  = dispatcher_answering(response([[refused]])).dispatch_flat(verb, {})

    expect(Hecks::Facade::CliRunner.refused_answer(result))
      .to eq(refused_reactions: [{ policy: "Gate", trigger: "D::Admit", reason: "no" }])
  end
end
