require "spec_helper"

# A fan-out's row id arrives as a bare `chit:` when the trigger acts on the fanned aggregate,
# and as `chit_id:` when the trigger stores it as a reference.
RSpec.describe "a for_each policy's row id" do
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
  def boot_keys
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "FanKey" do
        aggregate "Chit" do
          # Not `chit_id`: an identity named after the aggregate would answer to the
          # suffixed key itself and mask the reference key under test.
          identified_by :serial
          attribute :serial, Serial
          attribute :holder, Holder
          attribute :condition, ChitState

          value_object("Serial")    { attribute :value, String }
          value_object("Holder")    { attribute :value, String }
          value_object("ChitState") { attribute :value, String }
          # A policy forwards the event's whole payload, so `Void` must declare `alarm:`
          # or the delivery is refused as UnknownArgument for an unrelated reason.
          value_object("AlarmRef")  { attribute :value, String }

          command "Issue" do
            attribute :serial, Serial
            attribute :holder, Holder
            sets :serial
            sets :holder
            sets :condition, to: { value: "live" }
            emits "Issued"
          end

          # Acts on the chit — addressed by the bare reference key.
          command "Void" do
            reference_to Chit
            attribute :holder, Holder,   optional: true
            attribute :alarm,  AlarmRef, optional: true
            sets :condition, to: { value: "void" }
            emits "Voided"
          end

          query "LiveForHolder" do
            attribute :holder, Holder
            where(holder: :holder, "condition.value": "live")
          end
        end

        # Stores a chit rather than being one: the foreign-reference half.
        aggregate "Audit" do
          identified_by :note
          attribute :note, Note
          reference_to Chit

          value_object("Note") { attribute :value, String }

          command "Record" do
            attribute :note,   Note
            attribute :holder, Holder, optional: true
            sets :note
            emits "Recorded"
          end
        end

        aggregate "Alarm" do
          identified_by :alarm
          attribute :alarm,  AlarmRef
          attribute :holder, Holder

          value_object("AlarmRef") { attribute :value, String }
          value_object("Holder")   { attribute :value, String }

          command "Raise" do
            attribute :alarm,  AlarmRef
            attribute :holder, Holder
            sets :alarm
            sets :holder
            emits "Raised"
          end
        end

        policy "VoidChitsOnAlarm" do
          on       "Raised"
          for_each "Chit.LiveForHolder"
          trigger  Chit::Void
        end
      end

      Hecks.hecksagon("FanKey") do
        FanKey::Chit.persisted_by("Memory")
        FanKey::Audit.persisted_by("Memory")
        FanKey::Alarm.persisted_by("Memory")
      end
    end

    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def issue(runtime, serial, holder)
    runtime.dispatch_flat("FanKey::Chit.Issue", serial: { value: serial }, holder: { value: holder })
  end

  def raise_alarm(runtime, holder)
    runtime.dispatch_flat("FanKey::Alarm.Raise", alarm: { value: "al-1" }, holder: { value: holder })
  end

  # Two chits held by h1 and one by h2, then an alarm raised against h1.
  def alarmed_chits
    runtime = boot_keys
    [["chit-1", "h1"], ["chit-2", "h1"], ["chit-3", "h2"]].each { |serial, holder| issue(runtime, serial, holder) }
    raise_alarm(runtime, "h1")
    runtime
  end

  it "reaches a trigger that acts on the fanned aggregate, by its bare reference key", :aggregate_failures do
    runtime = alarmed_chits

    fan = runtime.reactions.select { |row| row[:policy] == "VoidChitsOnAlarm" }
    expect(fan.map { |row| row[:for_row] }).to contain_exactly("chit-1", "chit-2")
    expect(fan).to all(include(delivered: true))
    # A different holder's chit is outside the query's answer.
    expect(["chit-1", "chit-2", "chit-3"].map { |id| FanKey::Chit.find(id).condition[:value] }).to eq(["void", "void", "live"])
  end

  it "names the row id for the trigger, not for the aggregate it came from" do
    runtime = boot_keys
    issue(runtime, "chit-1", "h1")

    raise_alarm(runtime, "h1")

    # Pins against the refusal `Void does not declare chit_id — it takes `.
    reasons = runtime.reactions.filter_map { |row| row[:reason] }
    expect(reasons).to be_empty
  end
end
