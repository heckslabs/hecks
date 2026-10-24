require "spec_helper"

# `Hecks::Refused` is the parent of every domain refusal and of nothing else (ADR 0120), so
# `rescue Hecks::Refused` and `rescue *Runtime::DOMAIN_REFUSALS` catch the same set.
RSpec.describe Hecks::Refused do
  DISPATCH_ORDER_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook")

  def runtime
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(DISPATCH_ORDER_FIXTURE)
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def open_widget(**args)
    runtime.dispatch_flat("DispatchOrder::Widget.Open", label: { value: "w1" }, **args)
  end

  def refusal_from
    yield
    nil
  rescue described_class => e
    e
  end

  # Direct children only: an adapter's own refusal may narrow one of them (a NotFound that
  # names a missing checkout) and is still caught by rescuing its parent.
  def refused_classes = ObjectSpace.each_object(Class).select { |klass| klass.superclass == described_class }

  it "is the parent of every class DOMAIN_REFUSALS names" do
    expect(Hecks::Runtime::DOMAIN_REFUSALS).to all(be < described_class)
  end

  it "is the parent of nothing DOMAIN_REFUSALS leaves out" do
    expect(refused_classes).to match_array(Hecks::Runtime::DOMAIN_REFUSALS)
  end

  it "keeps runtime faults out", :aggregate_failures do
    expect(Hecks::Runtime::StaleWrite).not_to be < described_class
    expect(Hecks::Runtime::WiringError).not_to be < described_class
    expect(Hecks::Runtime::PluginRefusal).not_to be < described_class
  end

  it "carries no attribute unless the raise names one" do
    expect(Hecks::Runtime::NotFound.new("gone").attribute).to be_nil
  end

  it "keeps GivenNotMet's detail beside the attribute", :aggregate_failures do
    refusal = Hecks::Runtime::GivenNotMet.new("no", detail: "left: 1, right: 2", attribute: "amount")
    expect(refusal.detail).to eq("left: 1, right: 2")
    expect(refusal.attribute).to eq(:amount)
  end

  it "names the first absent argument, in the order the message lists them" do
    expect(refusal_from { open_widget }.attribute).to eq(:amount)
  end

  it "names the unknown argument it refused" do
    refusal = refusal_from do
      open_widget(amount: { value: 1 }, part_sequence: { value: 1 }, part_note: { value: "n" }, bogus: 1)
    end
    expect(refusal.attribute).to eq(:bogus)
  end
end
