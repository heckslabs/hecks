require "spec_helper"

# ADR 0081: a command that declares `needs :now` has the runtime answer the clock port before any
# given runs, unless the caller named a time of its own. The answer rides in the command's own
# arguments, so the stored record carries it and a replay does not ask again.
RSpec.describe "a command that needs :now" do
  # A fixed clock: the answer must be the bound adapter's, never the real time.
  module NeedsFixedClock
    module_function

    def now = 5_000
  end

  def boot_pilot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "NeedsPilot" do
        aggregate "Link" do
          attribute :ref, Ref
          attribute :issued_at, Instant, optional: true
          identified_by :ref

          value_object("Ref")     { attribute :value, String }
          value_object("Instant") { attribute :value, Integer }

          command "Issue" do
            attribute :ref, Ref
            attribute :now, Instant
            needs :now
            given("the link is issued at or after the epoch") { now.value >= 0 }
            sets :ref
            sets :issued_at, to: :now
            emits Issued
          end

          # No `needs`: the caller must name the time, as before.
          command "Stamp" do
            attribute :ref, Ref
            attribute :now, Instant
            sets :ref
            sets :issued_at, to: :now
            emits Stamped
          end
        end
      end

      stub_const("Hecks::Adapters::NeedsClock", NeedsFixedClock)
      Hecks.adapter("NeedsClock") { port "clock" }
      Hecks.hecksagon("NeedsPilot") { NeedsPilot::Link.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_pilot }

  def issued_at(handle) = handle.instance.state[:issued_at].to_h.values.first

  it "fills the time from the bound clock when the caller names none" do
    handle = runtime.dispatch_flat("NeedsPilot::Link.Issue", ref: { value: "a" })

    expect(issued_at(handle)).to eq(5_000)
  end

  it "keeps a time the caller names" do
    handle = runtime.dispatch_flat("NeedsPilot::Link.Issue", ref: { value: "b" }, now: { value: 42 })

    expect(issued_at(handle)).to eq(42)
  end

  it "leaves a command without `needs` to its caller" do
    expect { runtime.dispatch_flat("NeedsPilot::Link.Stamp", ref: { value: "c" }) }
      .to raise_error(StandardError, /now/)
  end

  it "runs a given against the filled time" do
    expect { runtime.dispatch_flat("NeedsPilot::Link.Issue", ref: { value: "d" }, now: { value: -1 }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /issued at or after the epoch/)
  end
end
