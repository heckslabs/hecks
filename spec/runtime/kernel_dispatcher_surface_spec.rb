require "hecks"
require "hecks/rust_build/kernel_client"
require "hecks/runtime/kernel_dispatcher"

# The kernel dispatcher's surface against a stand-in client: no kernel binary is built or run.
RSpec.describe Hecks::Runtime::KernelDispatcher do
  let(:client) { instance_double(Hecks::RustBuild::KernelClient) }
  let(:registry) { instance_double(Hecks::Runtime::Registry, verbs: ["Pizzas::Order.CreatePizza"], bluebook: nil) }
  let(:dispatcher) { described_class.new(client, registry: registry) }
  let(:refused) { { "ok" => false, "error" => "no Order \"x\"", "refusal" => "NotFound", "refusals" => [] } }

  describe "dry_run?" do
    it "is true when the kernel refuses nothing" do
      allow(client).to receive(:call).and_return("ok" => true)
      expect(dispatcher.dry_run?("Pizzas::Order.CreatePizza", name: "a")).to be(true)
    end

    it "raises the domain refusal the kernel names, with its message" do
      allow(client).to receive(:call).and_return(refused)
      expect { dispatcher.dry_run?("Pizzas::Order.Purchase") }.to raise_error(Hecks::Runtime::NotFound, "no Order \"x\"")
    end

    it "raises Refused for a refusal class outside the domain refusals" do
      allow(client).to receive(:call).and_return(refused.merge("refusal" => "Fault"))
      expect { dispatcher.dry_run?("Pizzas::Order.Purchase") }.to raise_error(described_class::Refused)
    end

    it "carries the attribute the kernel names" do
      entry = { "attribute" => "name", "path" => nil, "rule" => nil }
      allow(client).to receive(:call).and_return(refused.merge("refusal" => "UnknownArgument", "refusals" => [entry]))
      expect { dispatcher.dry_run?("Pizzas::Order.Purchase") }.to raise_error(having_attributes(attribute: :name))
    end
  end

  describe "a dispatch addressed with to:" do
    it "sends the receiver and facts as one step" do
      allow(client).to receive(:call).and_return("ok" => true, "events" => [])
      dispatcher.dispatch("Pizzas::Order.Purchase", to: "id-1", with: { amount: 1 })
      expect(client).to have_received(:call).with("verb" => "Pizzas::Order.Purchase", "to" => "id-1", "with" => { amount: 1 })
    end

    it "is refused with the kernel's text" do
      allow(client).to receive(:call).and_return("ok" => false, "error" => "nope")
      expect { dispatcher.dispatch("Pizzas::Order.Purchase", to: "id-1") }.to raise_error(described_class::Refused, "nope")
    end
  end

  describe "a refused flat dispatch" do
    before { allow(client).to receive(:dispatch).and_return("ok" => false, "error" => "nope") }

    it "is raised as the class the same step's dry run names, with the dispatch's text" do
      allow(client).to receive(:call).and_return(refused.merge("refusal" => "Unauthorized"))
      expect { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza") }.to raise_error(Hecks::Runtime::Unauthorized, "nope")
    end

    it "is raised as Refused when the dry run names nothing" do
      allow(client).to receive(:call).and_return("ok" => true)
      expect { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza") }.to raise_error(described_class::Refused, "nope")
    end
  end

  describe "the described declarations" do
    it "answers verbs from the registry" do
      expect(dispatcher.verbs).to eq(["Pizzas::Order.CreatePizza"])
    end

    it "is not answered without a registry" do
      expect { described_class.new(client).registry }.to raise_error(described_class::NotAnswered, /registry/)
    end
  end

  describe "what the protocol does not carry yet" do
    %i[reactions sagas outbox].each do |reader|
      it "raises NotAnswered for #{reader}" do
        expect { dispatcher.public_send(reader) }.to raise_error(described_class::NotAnswered, /#{reader}/)
      end
    end

    it "raises NotAnswered for a query" do
      expect { dispatcher.query("Pizzas::Order.Expensive") }.to raise_error(described_class::NotAnswered, /query step/)
    end
  end

  describe "what a dispatch settled on" do
    let(:announced) { { "ok" => true, "events" => [{ "name" => "Created", "aggregate" => "Pizzas::Order", "id" => "p-1" }] } }

    it "names the identity its first event names" do
      allow(client).to receive(:dispatch).and_return(announced)
      expect(dispatcher.dispatch_flat("Pizzas::Order.CreatePizza").id).to eq("p-1")
    end

    it "answers no reaction records, which the kernel's answer does not carry yet" do
      allow(client).to receive(:dispatch).and_return(announced)
      expect(dispatcher.dispatch_flat("Pizzas::Order.CreatePizza").refused_reactions).to eq([])
    end
  end

  describe "the declarations" do
    it "reads records from the kernel, not the registry" do
      order = instance_double(Hecks::Bluebook::Aggregate, name: "Order")
      expect(dispatcher.repository("Pizzas", order)).to be_a(described_class::Repository)
    end

    it "refuses a plan by name" do
      expect { dispatcher.plan_flat("Pizzas::Order.CreatePizza") }.to raise_error(described_class::NotAnswered, /plan step/)
    end
  end

  describe "reset!" do
    before { allow(client).to receive(:call).and_return("ok" => true) }

    it "keeps a snapshot the first time and restores it after", :aggregate_failures do
      2.times { dispatcher.reset! }
      expect(client).to have_received(:call).with("snapshot" => true).ordered
      expect(client).to have_received(:call).with("restore" => true).ordered
    end
  end

  describe "the bound caller" do
    it "rides on a dispatch as its role" do
      allow(client).to receive(:dispatch).and_return("ok" => true, "events" => [])
      Hecks::Runtime::Caller.as(role: "Chef") { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza") }
      expect(client).to have_received(:dispatch).with("Pizzas::Order.CreatePizza", {}, caller: { "role" => "Chef" })
    end
  end

  describe "redrive_sagas!" do
    it "has nothing to finish" do
      expect(dispatcher.redrive_sagas!).to be_nil
    end
  end

  describe "a dry run inside an open dispatch" do
    it "is refused by name" do
      allow(client).to receive(:dispatch) { dispatcher.dry_run?("Pizzas::Order.CreatePizza") }
      expect { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza") }.to raise_error(described_class::NestedDispatch)
    end
  end
end
