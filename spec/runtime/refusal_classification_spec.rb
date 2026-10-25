require "spec_helper"
require "tempfile"
require_relative "../support/memory_ports"

# Which sort of no a refusal is, where in dispatch it came from, and which rule said it: rows of the
# language's RefusalClass table plus what a raise site names, so a client can act on it as data.
RSpec.describe Hecks::Refused, "#stage" do
  GATED_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Gated" do
      aggregate "Tap" do
        identified_by :name
        attribute :name, Name
        attribute :flow, Flow
        value_object("Name") { attribute :value, String }
        value_object("Flow") { attribute :value, Integer }
        lifecycle :status, default: "shut" do
          transition "Run" => "running", from: "shut"
        end
        command("Install") do
          attribute :name, Name
          attribute :flow, Flow
          sets :name
          sets :flow
          emits "TapInstalled"
        end
        command("Run", from: "shut") do
          reference_to Tap
          given("the flow is positive") { flow.value > 0 }
          emits "TapRan"
        end
      end
    end
  BLUEBOOK

  def boot_gated
    file = Tempfile.new(["gated-", ".bluebook"])
    file.write(GATED_SOURCE)
    file.flush
    registry = declare_gated(file.path)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

  def declare_gated(path)
    Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        Kernel.eval(GATED_SOURCE, TOPLEVEL_BINDING, path, 1)
        Hecks.hecksagon("Gated") { Gated::Tap.persisted_by("Memory") }
      end
    end
  end

  def refusal_from
    yield
    nil
  rescue described_class => e
    e
  end

  def install(dispatcher, flow)
    dispatcher.dispatch_flat("Gated::Tap.Install", name: { value: "t1" }, flow: { value: flow })
  end

  it "classes every domain refusal in the vocabulary, and nothing else" do
    expect(described_class::CLASSES.keys).to match_array(Hecks::Vocabulary.fetch("DomainRefusal"))
  end

  it "reads kind and stage from the table", :aggregate_failures do
    refusal = Hecks::Runtime::Unauthorized.new("no role")

    expect(refusal.kind).to eq(:unauthorized)
    expect(refusal.stage).to eq(:role)
  end

  it "lets a raise site name a narrower stage" do
    expect(Hecks::Runtime::NotFound.new("gone", stage: :references).stage).to eq(:references)
  end

  it "points a path at the attribute unless the raise gives one", :aggregate_failures do
    expect(Hecks::Runtime::TypeMismatch.new("bad", attribute: :email).path).to eq("/email")
    expect(Hecks::Runtime::TypeMismatch.new("bad", attribute: :cents, path: "/balance/cents").path).to eq("/balance/cents")
  end

  it "answers the refusal as plain data" do
    refusal = Hecks::Runtime::GivenNotMet.new("no", attribute: :flow, rule: "the flow is positive")

    expect(refusal.to_h).to eq(kind: :refused, stage: :givens, attribute: :flow, path: "/flow",
                               rule: "the flow is positive", message: "no")
  end

  it "names the given that refused, in the givens stage", :aggregate_failures do
    dispatcher = boot_gated
    install(dispatcher, 0)
    refusal = refusal_from { dispatcher.dispatch("Gated::Tap.Run", to: "t1") }

    expect(refusal.stage).to eq(:givens)
    expect(refusal.rule).to eq("the flow is positive")
  end
end
