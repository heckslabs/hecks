require "spec_helper"

# A command attribute's declared `default:` fills an argument the caller leaves out, on every way
# in: the flat call, the `with:` envelope and a delegated command. An argument the caller passes is
# kept, and an attribute with no default is still required.
RSpec.describe "command attribute defaults" do
  before(:all) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "CommandDefaults" do
        aggregate "Trial" do
          attribute :ref, Ref
          attribute :runs, Count, optional: true
          attribute :label, Label, optional: true
          identified_by :ref

          value_object("Ref")   { attribute :value, String }
          value_object("Count") { attribute :value, Integer }
          value_object("Label") { attribute :value, String }

          command "Start" do
            attribute :ref, Ref
            attribute :runs, Count, default: 30
            attribute :label, Label
            sets :ref
            sets :runs
            sets :label
            emits "Started"
          end
        end
      end

      Hecks.hecksagon("CommandDefaults") { CommandDefaults::Trial.persisted_by("Memory") }
    end

    registry.verify!
    @runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { @runtime }

  def runs_of(handle) = handle.instance.state[:runs].to_h.values.first

  it "fills an omitted argument with its declared default" do
    handle = runtime.dispatch_flat("CommandDefaults::Trial.Start", ref: { value: "a" }, label: { value: "x" })

    expect(runs_of(handle)).to eq(30)
  end

  it "keeps an argument the caller passes" do
    handle = runtime.dispatch_flat("CommandDefaults::Trial.Start", ref: { value: "b" }, runs: { value: 7 },
                                                                  label: { value: "x" })

    expect(runs_of(handle)).to eq(7)
  end

  it "fills it in the strict `with:` envelope too" do
    handle = runtime.dispatch("CommandDefaults::Trial.Start", with: { ref: { value: "c" }, label: { value: "x" } })

    expect(runs_of(handle)).to eq(30)
  end

  it "still requires an attribute that has no default" do
    expect { runtime.dispatch_flat("CommandDefaults::Trial.Start", ref: { value: "d" }) }
      .to raise_error(Hecks::Runtime::AbsentArgument, /label/)
  end
end
