require "spec_helper"

# command_interpreter/argument_gate.rb names this "the weakest part of the
# gate": a saga's correlation key legitimately arrives on commands that
# never declare it, because `correlation_keys` widens the allow-list
# domain-wide. `deliver_saga_dispatch` now stamps the key it already knows
# onto the event(s) its own dispatch causes, so a leg that stops smuggling
# the key through its with-spec still correlates — closing the gap
# additively, without removing the smuggle path any existing saga relies on.
RSpec.describe "a saga leg that never declares the correlation key at all" do
  def boot_beacon
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Beacon", version: "v1" do
        aggregate "Sighting" do
          identified_by :code

          attribute :code, SightingCode

          value_object "SightingCode" do
            attribute :value, String

            invariant("a sighting is coded") { !value.to_s.empty? }
          end

          command "Raise" do
            attribute :code, SightingCode
            emits "SightingRaised"
          end
        end

        aggregate "Alarm" do
          identified_by :label

          attribute :label, AlarmLabel

          value_object "AlarmLabel" do
            attribute :value, String

            invariant("an alarm is labeled") { !value.to_s.empty? }
          end

          # NEVER DECLARES `code` — the argument this leg's dispatch binds
          # is `label`, a DIFFERENT name entirely. Nothing about this
          # command's own declaration has anything to do with a sighting.
          command "Open" do
            attribute :label, AlarmLabel
            emits "AlarmOpened"
          end
        end

        process_manager "Watch" do
          correlates_by :"code.value"
          starts_on "SightingRaised"
          ends_on   "AlarmOpened"

          state "watching"

          on "SightingRaised", transition: { "watching" => "watching" } do
            # A LITERAL, wholly unconnected to the sighting's code — this leg
            # passes nothing correlation-shaped at all. AlarmOpened's payload
            # carries `label`, never `code`, so the payload-lookup tier finds
            # nothing here on purpose. Nor does the own-reference-key
            # fallback : Alarm's own reference key is "alarm", not "code".
            # Only the stamp resolves it.
            dispatch Alarm::Open, with: { label: { value: "backup" } }
          end
        end
      end

      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  it "still ends the right instance, correlated by the stamp alone" do
    runtime = boot_beacon
    runtime.dispatch("Beacon::Sighting.Raise", code: { value: "smoke-1" })

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Watch", instance: "smoke-1", born: true)
    )
    expect(runtime.sagas).to include(
      hash_including(process_manager: "Watch", instance: "smoke-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Watch"]).to be_empty
  end
end
