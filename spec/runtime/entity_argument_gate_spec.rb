require "spec_helper"

# An entity command runs the same argument gate as an aggregate command, with the entity
# chain's identity heads (`sequence:`, `label:`) counted as addressing, not unknown arguments.
RSpec.describe "an entity command's own argument gate" do
  DISPATCH_ORDER = File.join(InMemoryDomain::ROOT, "spec/fixtures/dispatch_order.bluebook")

  def boot
    @registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(@registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DISPATCH_ORDER)
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(@registry))
  end

  def open_widget(runtime)
    runtime.dispatch_flat("DispatchOrder::Widget.Open", label: { value: "w1" }, amount: { value: 1 },
                          part_sequence: { value: 1 }, part_note: { value: "first" })
  end

  let(:runtime) { boot.tap { |booted| open_widget(booted) } }

  def part(verb, **args)
    runtime.dispatch_flat("DispatchOrder::Widget.Part.#{verb}", label: { value: "w1" }, sequence: { value: 1 }, **args)
  end

  def stored_note
    widget = @registry.bluebook("DispatchOrder").aggregates.find { |a| a.hecks_name == "Widget" }
    @registry.repository("DispatchOrder", widget).find("w1").state[:parts].first[:note].value
  end

  it "refuses an argument the entity command does not declare" do
    expect { part("Advance", note: { value: "moved" }, bogus_arg: 123) }
      .to raise_error(Hecks::Runtime::UnknownArgument, /bogus_arg/)
  end

  it "refuses a declared argument that was simply left out, rather than silently nil-ing the field it sets",
     :aggregate_failures do
    expect { part("Advance") }.to raise_error(Hecks::Runtime::AbsentArgument, /note/)

    # Pins the refusal happening before any mutation: an omitted `note` must not overwrite
    # `parts[0].note` with nil.
    expect(stored_note).to eq("first")
  end

  it "does not mistake the entity's own identity, or the root's, for an unknown argument" do
    expect { part("Advance", note: { value: "moved" }) }.not_to raise_error
  end

  it "still refuses an unknown argument on a command that transitions nothing" do
    expect { part("Touch", note: { value: "touched" }, sneaky: "x") }
      .to raise_error(Hecks::Runtime::UnknownArgument, /sneaky/)
  end
end
