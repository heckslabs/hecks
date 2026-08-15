
require "spec_helper"

# THE NAME A FAN-OUT'S ROW ID ARRIVES UNDER.
#
# `spec/runtime/policy_spec.rb` already covers `for_each` end to end and
# asserts delivery — and passed for a reason that was not the rule. Its
# `Fanout::Account` is `identified_by :account_id` over an
# `attribute :account_id`, so the row id merged as `account_id:` matched
# the aggregate's own IDENTITY HEAD directly and never needed the
# reference key at all. Every aggregate in the real corpus names its
# identity something else (`Account` is `identified_by AccountNumber,
# as: :number`), so the same policy shape refused there with
# `UnknownArgument` naming a key the command could not take, and the
# refusal was recorded per row in the reaction log rather than raised
# anywhere a caller would look.
#
# So this fixture deliberately does NOT name its identity after itself.
# It is the difference between the two spellings, isolated:
#
#   trigger acts on the fanned aggregate -> bare `chit:`
#   trigger stores it as a reference     -> `chit_id:`
RSpec.describe "a for_each policy's row id" do
  def boot_keys
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "FanKey" do
        aggregate "Chit" do
          # NOT `chit_id` — that is the whole point. An identity head
          # spelled after the aggregate would mask the reference key by
          # answering to the suffixed name itself.
          identified_by :serial
          attribute :serial, Serial
          attribute :holder, Holder
          attribute :condition, ChitState

          value_object("Serial")    { attribute :value, String }
          value_object("Holder")    { attribute :value, String }
          value_object("ChitState") { attribute :value, String }
          # A policy forwards the triggering event's WHOLE payload, so a
          # trigger has to be able to take every field the event carries
          # — `Void` declaring nothing for `alarm:` is the ordinary
          # UnknownArgument refusal, not the key bug under test here.
          value_object("AlarmRef")  { attribute :value, String }

          command "Issue" do
            attribute :serial, Serial
            attribute :holder, Holder
            sets :serial
            sets :holder
            sets :condition, to: { value: "live" }
            emits "Issued"
          end

          # ACTS ON the chit — addressed by the bare reference key.
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

        # A SECOND AGGREGATE that STORES a chit rather than being one —
        # the foreign-reference half of the same rule.
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
          trigger  "Chit.Void"
        end
      end

      Hecks.hecksagon("FanKey") do
        ::FanKey::Chit.persisted_by("Memory")
        ::FanKey::Audit.persisted_by("Memory")
        ::FanKey::Alarm.persisted_by("Memory")
      end
    end

    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def issue(runtime, serial, holder)
    runtime.dispatch("FanKey::Chit.Issue", serial: { value: serial }, holder: { value: holder })
  end

  it "reaches a trigger that acts on the fanned aggregate, by its bare reference key" do
    runtime = boot_keys
    issue(runtime, "chit-1", "h1")
    issue(runtime, "chit-2", "h1")
    issue(runtime, "chit-3", "h2")

    runtime.dispatch("FanKey::Alarm.Raise", alarm: { value: "al-1" }, holder: { value: "h1" })

    fan = runtime.reactions.select { |row| row[:policy] == "VoidChitsOnAlarm" }
    expect(fan.map { |row| row[:for_row] }).to contain_exactly("chit-1", "chit-2")
    expect(fan).to all(include(delivered: true))

    expect(FanKey::Chit.find("chit-1").condition[:value]).to eq("void")
    expect(FanKey::Chit.find("chit-2").condition[:value]).to eq("void")
    # A DIFFERENT HOLDER'S CHIT is outside the query's answer.
    expect(FanKey::Chit.find("chit-3").condition[:value]).to eq("live")
  end

  it "names the row id for the trigger, not for the aggregate it came from" do
    runtime = boot_keys
    issue(runtime, "chit-1", "h1")

    runtime.dispatch("FanKey::Alarm.Raise", alarm: { value: "al-1" }, holder: { value: "h1" })

    # The refusal this asserts the ABSENCE of is the exact one the bug
    # produced: `Void does not declare chit_id — it takes `.
    reasons = runtime.reactions.filter_map { |row| row[:reason] }
    expect(reasons).to be_empty
  end
end
