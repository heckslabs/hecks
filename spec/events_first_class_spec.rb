require "spec_helper"

# `emits`/`on` accept a bare event constant (`emits Account::AccountFrozen`) or the
# quoted-string form; both are admitted (ADR 0025).
RSpec.describe "events first-class (ADR 0025, S6)" do
  # The fixtures below are scaffolding procs, `instance_eval`d where needed; DSL words and
  # constants resolve against the active `self`, not where the proc is defined.
  def number_identity
    proc do
      identified_by do
        attribute :number, String
      end
    end
  end

  def make_emitting_qualified
    proc do
      command "Make" do
        role "Maker"
        goal "Make one"

        emits Widget::WidgetMade
      end
    end
  end

  def make_emitting_bare
    proc do
      command "Make" do
        role "Maker"
        goal "Make one"

        emits WidgetMade
      end
    end
  end

  def make_emitting_quoted
    proc do
      command "Make" do
        role "Maker"
        goal "Make one"

        emits "WidgetMade"
      end
    end
  end

  def finish_emitting_bare
    proc do
      command "Finish" do
        role "Maker"
        goal "Finish one"

        emits WidgetFinished
      end
    end
  end

  def note_command
    proc do
      command "Note" do
        role "Recorder"
        goal "Note that something happened"
      end
    end
  end

  def note_command_with_field
    proc do
      command "Note" do
        role "Recorder"
        goal "Note that something happened"

        attribute :nonexistent_field, String
      end
    end
  end

  def record_policy_on_constant
    proc do
      policy "RecordWidgetMade" do
        on      Widget::WidgetMade
        trigger Ledger::Note
      end
    end
  end

  def record_policy_on_string
    proc do
      policy "RecordWidgetMade" do
        on      "Widget.WidgetMade"
        trigger Ledger::Note
      end
    end
  end

  def record_policy_with_projection
    proc do
      policy "RecordWidgetMade" do
        on      Widget::WidgetMade
        trigger Ledger::Note, with: { nonexistent_field: :nonexistent_field }
      end
    end
  end

  def lifecycle_on_constants
    proc do
      process_manager "WidgetLifecycle" do
        correlates_by :"number.value"
        starts_on Widget::WidgetMade
        ends_on   Widget::WidgetFinished

        transition Widget::WidgetMade => "made", from: "made"
      end
    end
  end

  def lifecycle_on_quoted
    proc do
      process_manager "WidgetLifecycle" do
        correlates_by :"number.value"
        starts_on "WidgetMade"
        ends_on   "WidgetMade"

        transition "WidgetMade" => "made", from: "made"
      end
    end
  end

  def widget_aggregate(*commands)
    identity = number_identity
    proc do
      aggregate "Widget" do
        instance_eval(&identity)
        commands.each { |command| instance_eval(&command) }
      end
    end
  end

  def ledger_aggregate(*parts)
    identity = number_identity
    proc do
      aggregate "Ledger" do
        instance_eval(&identity)
        parts.each { |part| instance_eval(&part) }
      end
    end
  end

  # Builds a bluebook out of the scaffolding procs, replayed in order after its vision.
  def build_events_bluebook(name, vision_text, *parts)
    Hecks::Bluebook::DSL::BluebookBuilder.build(name) do
      vision vision_text
      parts.each { |part| instance_eval(&part) }
    end
  end

  def find_aggregate(bluebook, name) = bluebook.aggregates.find { |a| a.hecks_name == name }

  # A bare qualified event constant on starts_on/ends_on/transition resolves to the same bare
  # name a same-aggregate emits already stores — unlike on, which keeps its qualifier.
  def bare_starts_ends_on_ir
    parts = [widget_aggregate(make_emitting_bare, finish_emitting_bare), lifecycle_on_constants]
    build_events_bluebook("EventsBareStartsEndsOn", "a bare qualified event constant on starts_on/ends_on/transition " \
                                                    "resolves to the SAME bare name", *parts)
  end

  def quoted_starts_ends_on_ir
    parts = [widget_aggregate(make_emitting_quoted), lifecycle_on_quoted]
    build_events_bluebook("EventsQuotedStartsEndsOnStillWorks",
                          "the quoted-string spelling is not refused for starts_on/ends_on either", *parts)
  end

  it "accepts a bare event constant on emits, same string as the quoted form would give" do
    ir = build_events_bluebook("EventsBareEmits", "a bare event constant on emits resolves the same as a quoted string",
                               widget_aggregate(make_emitting_qualified))

    expect(ir.aggregates.first.commands.first.emits).to eq(["Widget.WidgetMade"])
  end

  it "accepts a bare event constant on a policy's on, qualified the same as the quoted string form" do
    parts = [widget_aggregate(make_emitting_qualified), ledger_aggregate(note_command, record_policy_on_constant)]
    ir = build_events_bluebook("EventsBareOn", "a bare event constant on `on` resolves the same as a quoted " \
                                               "qualified string", *parts)

    expect(find_aggregate(ir, "Ledger").policies.first.on_event).to eq("Widget.WidgetMade")
  end

  # Does not reuse `make_emitting_qualified`: its bare constant is the very difference tested.
  it "still accepts the old quoted-string form for both emits and on, unchanged", :aggregate_failures do
    parts = [widget_aggregate(make_emitting_quoted), ledger_aggregate(note_command, record_policy_on_string)]
    ir = build_events_bluebook("EventsQuotedStillWorks", "the quoted-string spelling is not refused — only " \
                                                         "command references were 100% migrated", *parts)

    expect(find_aggregate(ir, "Widget").commands.first.emits).to eq(["WidgetMade"])
    expect(find_aggregate(ir, "Ledger").policies.first.on_event).to eq("Widget.WidgetMade")
  end

  it "still refuses a with: projection naming a field the triggering event does not declare" do
    parts = [widget_aggregate(make_emitting_qualified),
             ledger_aggregate(note_command_with_field, record_policy_with_projection)]

    expect { build_events_bluebook("EventsWithSpecStillChecked", "with: is still checked", *parts) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /off "Widget\.WidgetMade", which does not declare it/)
  end

  # Needs two distinct emitted events (Make/Finish), so it cannot reuse `make_emitting_qualified`.
  it "accepts a bare, qualified event constant on a process_manager's starts_on/ends_on/transition, but " \
     "stores only the bare event name — SagaInterpreter matches a bare event.name, never a dotted one", :aggregate_failures do
    pm = bare_starts_ends_on_ir.process_managers.first
    # A qualified constant stores the bare name here, unlike `on`/`emits`, which keep the ".".
    expect(pm.starts_on).to eq("WidgetMade")
    expect(pm.ends_on).to eq("WidgetFinished")
    expect(pm.handlers.first.event_type).to eq("WidgetMade")
  end

  it "keeps the same-aggregate emits bare beside a process_manager that names the qualified constant" do
    expect(bare_starts_ends_on_ir.aggregates.first.commands.first.emits).to eq(["WidgetMade"])
  end

  it "still accepts the old quoted-string form for starts_on/ends_on, unchanged", :aggregate_failures do
    pm = quoted_starts_ends_on_ir.process_managers.first

    expect(pm.starts_on).to eq("WidgetMade")
    expect(pm.ends_on).to eq("WidgetMade")
  end

  def boot_banking_runtime
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      InMemoryDomain.load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry.verify!
    [registry, Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))]
  end

  def register_and_open(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                          name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c1", number: { value: "ACC1" },
                          kind: { name: "current" }, daily_limit: { cents: 100_000 })
  end

  it "dispatches a real migrated corpus reaction end to end — FreezeAccount emits, ReviewOnFreeze reacts", :aggregate_failures do
    registry, runtime = boot_banking_runtime
    register_and_open(runtime)

    expect { runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "ACC1" }) }.not_to raise_error
    account = registry.repository("Banking", registry.bluebook("Banking").aggregate("Account")).find("ACC1")
    expect(account[:status]).to eq("frozen")
  end
end
