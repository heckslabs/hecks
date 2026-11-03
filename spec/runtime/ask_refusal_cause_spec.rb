require "spec_helper"

# An ask whose adapter fails: the outside world saying no is the ask's `refuses` event, carrying a
# reason that is never empty, and a defect in the code (`Runtime::PROGRAMMING_ERRORS`) raises where
# it happens instead. Runs the corpus-owned Errand domain in Memory.
RSpec.describe "the cause an ask's refusal carries" do
  ASK_CAUSE_DOMAIN = File.join(InMemoryDomain::ROOT, "spec/corpus/asks/domain/bluebook").freeze

  module Hecks
    module Adapters
      # Answers the Errand Worker port, or raises the error a spec hands it.
      class AskCauseWorker
        class << self
          attr_accessor :failure
        end

        def run(ref:, **)
          raise self.class.failure if self.class.failure

          { ref: ref }
        end

        def audit(ref:, **) = { ref: ref }
      end

      # Answers the Errand Inspector port.
      class AskCauseInspector
        def audit(ref:, **) = { ref: ref }
      end
    end
  end

  def booted_errand
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, *%w[errand.bluebook errand.hecksagon].map { |file| File.join(ASK_CAUSE_DOMAIN, file) }]
        .each { |file| Kernel.load(file) }
      Hecks.adapter("AskCauseWorker") { port "Worker" }
      Hecks.adapter("AskCauseInspector") { port "Inspector" }
    end
    registry.verify!
    registry
  end

  let(:registry) { booted_errand }
  let(:dispatcher) { Hecks::Runtime::Dispatcher.new(registry) }

  before { dispatcher.dispatch_flat("Errand::Job.Request", ref: { value: "J1" }) }
  after  { Hecks::Adapters::AskCauseWorker.failure = nil }

  # Asks Worker.Run of J1 with the adapter raising `error`.
  def ask_failing_with(error)
    Hecks::Adapters::AskCauseWorker.failure = error
    dispatcher.dispatch_port("Errand", "Job", "Worker", "Run", to: "J1", with: { ref: { value: "J1" } })
  end

  def refusal_of(error) = ask_failing_with(error).first.payload[:refusal][:value]

  it "raises a NameError instead of refusing" do
    expect { ask_failing_with(NameError.new("uninitialized constant MintDecision")) }
      .to raise_error(NameError, /MintDecision/)
  end

  it "raises a NoMethodError instead of refusing" do
    expect { ask_failing_with(NoMethodError.new("undefined method `verdict' for nil")) }.to raise_error(NoMethodError)
  end

  it "raises a TypeError instead of refusing" do
    expect { ask_failing_with(TypeError.new("no implicit conversion of nil into String")) }.to raise_error(TypeError)
  end

  it "announces no refusal when the adapter's code is wrong", :aggregate_failures do
    expect { ask_failing_with(NameError.new("x")) }.to raise_error(NameError)
    expect(registry.event_log.map(&:name)).not_to include("JobRefused")
  end

  it "refuses an adapter's own refusal with its class and message", :aggregate_failures do
    events = ask_failing_with(Hecks::Runtime::WiringError.new("the gate could not run"))

    expect(events.map(&:name)).to eq(["JobRefused"])
    expect(events.first.payload[:refusal][:value]).to eq("Hecks::Runtime::WiringError: the gate could not run")
  end

  it "names the error's class when it was raised with no message" do
    expect(refusal_of(RuntimeError.new(""))).to eq("RuntimeError: raised with no message")
  end

  it "refuses an ArgumentError, which adapters raise to refuse their input" do
    expect(refusal_of(ArgumentError.new("no timeout to wait for the host with"))).to include("no timeout")
  end

  # Requests J2 with the Worker adapter's code wrong, and answers the Run policy's reaction.
  def defective_reaction
    Hecks::Adapters::AskCauseWorker.failure = NameError.new("uninitialized constant MintDecision")
    dispatcher.dispatch_flat("Errand::Job.Request", ref: { value: "J2" })
    registry.reaction_log.reverse.find { |reaction| reaction[:policy] == "RunWhenRequested" }
  end

  it "warns of a defect when a policy's ask meets a programming error" do
    expect { defective_reaction }.to output(/defect in reaction — policy RunWhenRequested/).to_stderr
  end

  it "records the policy's ask as a defect, not a refusal", :aggregate_failures do
    reaction = nil
    expect { reaction = defective_reaction }.to output.to_stderr
    expect(reaction).to include(defect: true, error_class: "NameError")
  end
end
