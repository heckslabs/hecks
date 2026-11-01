require "spec_helper"

# The push train's mint reactions, on a disposable domain shaped like the Hecks deliver domain: a
# Boarding aggregate identified by its run key, and a mint whose events carry that same run key.
RSpec.describe "a refused mint faults the boarding it was run for" do
  class RefusedMintRecordingDispatcher
    attr_reader :calls

    def initialize
      @calls = []
    end

    def reenter(verb, **arguments)
      @calls << [verb, arguments]
    end

    def reaction_depth_reached? = false
    def max_reaction_depth = 16
  end

  REFUSED_MINT_DOMAIN = proc do
    aggregate "Boarding" do
      attribute :run,     RunKey
      attribute :refusal, Refusal, optional: true
      identified_by :run

      value_object("RunKey")  { attribute :value, String }
      value_object("Refusal") { attribute :value, String }

      command "Fault" do
        reference_to Boarding
        attribute :refusal, Refusal, sets: true
        emits "BoardingFaulted"
      end

      command "Clear" do
        reference_to Boarding
        emits "BoardingCleared"
      end
    end

    policy "FaultWhenMintRefused" do
      on "MintRefused"
      trigger Boarding::Fault, with: { run: :run, refusal: :refusal }
    end

    policy "ClearWhenMinted" do
      on "Minted"
      trigger Boarding::Clear, with: { run: :run }
    end
  end

  def mint_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.bluebook("RefusedMintRouting", &REFUSED_MINT_DOMAIN) }
    registry
  end

  # The mint's own record is named `mint-1`, so a reaction that falls back to the event's receiver
  # would route to `mint-1` and fail this spec.
  def mint_event(name, payload)
    Hecks::Runtime::Event.new(name: name, aggregate: "Mint", id: "mint-1", payload: payload)
  end

  def react_to(event)
    dispatcher = RefusedMintRecordingDispatcher.new
    Hecks::Runtime::PolicyInterpreter.new(mint_registry, dispatcher: dispatcher).react(event, "RefusedMintRouting")
    dispatcher.calls
  end

  def refused_event
    mint_event("MintRefused", run: { value: "push-1" }, refusal: { value: "the decision is needs_edge" })
  end

  it "faults the boarding under the run key the refused mint carried" do
    expect(react_to(refused_event)).to eq(
      [["RefusedMintRouting::Boarding.Fault", { to: "push-1", with: { refusal: { value: "the decision is needs_edge" } } }]]
    )
  end

  it "clears the boarding and does not fault it when the mint is minted" do
    calls = react_to(mint_event("Minted", run: { value: "push-1" }, label: { value: "f30dcb" }))
    expect(calls).to eq([["RefusedMintRouting::Boarding.Clear", { to: "push-1", with: {} }]])
  end
end
