require "spec_helper"

# `deliver_saga_dispatch` stamps the known correlation key onto the events its dispatch causes,
# so a leg that never passes the key in its with-spec still correlates.
RSpec.describe "a saga leg that never declares the correlation key at all" do
  # One bluebook fixture; splitting it would break the single with_registry block scope.
  # rubocop:disable-next Metrics/MethodLength
  def boot_beacon
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
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

          # Never declares `code`; the leg's dispatch binds `label`.
          command "Open" do
            attribute :label, AlarmLabel
            emits "AlarmOpened"
          end
        end

        process_manager "Watch" do
          correlates_by :"code.value"
          starts_on "SightingRaised"
          ends_on   "AlarmOpened"

          transition "SightingRaised" => "watching", from: "watching" do
            # Passes nothing correlation-shaped: AlarmOpened carries `label`, not `code`,
            # and Alarm's own reference key is "alarm". Only the stamp resolves it.
            dispatch Alarm::Open, with: { label: { value: "backup" } }
          end
        end
      end

      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  it "still ends the right instance, correlated by the stamp alone" do
    runtime = boot_beacon
    runtime.dispatch_flat("Beacon::Sighting.Raise", code: { value: "smoke-1" })

    expect(runtime.sagas).to include(
      hash_including(process_manager: "Watch", instance: "smoke-1", born: true)
    )
    expect(runtime.sagas).to include(
      hash_including(process_manager: "Watch", instance: "smoke-1", ended: true)
    )
    expect(runtime.registry.saga_instances["Watch"]).to be_empty
  end
end
