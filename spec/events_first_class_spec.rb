require "spec_helper"

# `emits`/`on` accept a bare event constant (`emits Account::AccountFrozen`) or the
# quoted-string form; both are admitted (ADR 0025).
RSpec.describe "events first-class (ADR 0025, S6)" do
  # Scaffolding fixture, `instance_eval`d where needed; DSL words and constants
  # resolve against the active `self`, not where the proc is defined.
  def widget_emits_widget_made
    proc do
      aggregate "Widget" do
        identified_by do
          attribute :number, String
        end

        command "Make" do
          role "Maker"
          goal "Make one"

          emits Widget::WidgetMade
        end
      end
    end
  end

  it "accepts a bare event constant on emits, same string as the quoted form would give" do
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsBareEmits") do
      vision "a bare event constant on emits resolves the same as a quoted string"

      aggregate "Widget" do
        identified_by do
          attribute :number, String
        end

        command "Make" do
          role "Maker"
          goal "Make one"

          emits Widget::WidgetMade
        end
      end
    end

    expect(ir.aggregates.first.commands.first.emits).to eq(["Widget.WidgetMade"])
  end

  it "accepts a bare event constant on a policy's on, qualified the same as the quoted string form" do
    widget = widget_emits_widget_made
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsBareOn") do
      vision "a bare event constant on `on` resolves the same as a quoted qualified string"

      instance_eval(&widget)

      aggregate "Ledger" do
        identified_by do
          attribute :number, String
        end

        command "Note" do
          role "Recorder"
          goal "Note that something happened"
        end

        policy "RecordWidgetMade" do
          on      Widget::WidgetMade
          trigger Ledger::Note
        end
      end
    end

    policy = ir.aggregates.find { |a| a.hecks_name == "Ledger" }.policies.first
    expect(policy.on_event).to eq("Widget.WidgetMade")
  end

  # Does not reuse `widget_emits_widget_made`: its bare constant is the very difference tested.
  # rubocop:disable-next RSpec/ExampleLength
  it "still accepts the old quoted-string form for both emits and on, unchanged" do
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsQuotedStillWorks") do
      vision "the quoted-string spelling is not refused — only command references were 100% migrated"

      aggregate "Widget" do
        identified_by do
          attribute :number, String
        end

        command "Make" do
          role "Maker"
          goal "Make one"

          emits "WidgetMade"
        end
      end

      aggregate "Ledger" do
        identified_by do
          attribute :number, String
        end

        command "Note" do
          role "Recorder"
          goal "Note that something happened"
        end

        policy "RecordWidgetMade" do
          on      "Widget.WidgetMade"
          trigger Ledger::Note
        end
      end
    end

    expect(ir.aggregates.find { |a| a.hecks_name == "Widget" }.commands.first.emits).to eq(["WidgetMade"])
    expect(ir.aggregates.find { |a| a.hecks_name == "Ledger" }.policies.first.on_event).to eq("Widget.WidgetMade")
  end

  it "still refuses a with: projection naming a field the triggering event does not declare" do
    widget = widget_emits_widget_made

    expect do
      Hecks::Bluebook::DSL::BluebookBuilder.build("EventsWithSpecStillChecked") do
        vision "with: is still checked against the triggering event's real shape, bare constant or not"

        instance_eval(&widget)

        aggregate "Ledger" do
          identified_by do
            attribute :number, String
          end

          command "Note" do
            role "Recorder"
            goal "Note that something happened"

            attribute :nonexistent_field, String
          end

          policy "RecordWidgetMade" do
            on      Widget::WidgetMade
            trigger Ledger::Note, with: { nonexistent_field: :nonexistent_field }
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /off "Widget\.WidgetMade", which does not declare it/)
  end

  # Needs two distinct emitted events (Make/Finish), so it cannot reuse `widget_emits_widget_made`.
  # rubocop:disable-next RSpec/ExampleLength
  it "accepts a bare, qualified event constant on a process_manager's starts_on/ends_on/transition, but " \
     "stores only the bare event name — SagaInterpreter matches a bare event.name, never a dotted one" do
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsBareStartsEndsOn") do
      vision "a bare qualified event constant on starts_on/ends_on/transition resolves to the SAME bare " \
             "name a same-aggregate emits already stores — unlike on, which keeps its qualifier"

      aggregate "Widget" do
        identified_by do
          attribute :number, String
        end

        command "Make" do
          role "Maker"
          goal "Make one"

          emits WidgetMade
        end

        command "Finish" do
          role "Maker"
          goal "Finish one"

          emits WidgetFinished
        end
      end

      process_manager "WidgetLifecycle" do
        correlates_by :"number.value"
        starts_on Widget::WidgetMade
        ends_on   Widget::WidgetFinished

        transition Widget::WidgetMade => "made", from: "made"
      end
    end

    pm = ir.process_managers.first
    # A qualified constant stores the bare name here, unlike `on`/`emits`, which keep the ".".
    expect(pm.starts_on).to eq("WidgetMade")
    expect(pm.ends_on).to eq("WidgetFinished")
    expect(pm.handlers.first.event_type).to eq("WidgetMade")
    expect(ir.aggregates.first.commands.first.emits).to eq(["WidgetMade"])
  end

  it "still accepts the old quoted-string form for starts_on/ends_on, unchanged" do
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsQuotedStartsEndsOnStillWorks") do
      vision "the quoted-string spelling is not refused for starts_on/ends_on either"

      aggregate "Widget" do
        identified_by do
          attribute :number, String
        end

        command "Make" do
          role "Maker"
          goal "Make one"

          emits "WidgetMade"
        end
      end

      process_manager "WidgetLifecycle" do
        correlates_by :"number.value"
        starts_on "WidgetMade"
        ends_on   "WidgetMade"

        transition "WidgetMade" => "made", from: "made"
      end
    end

    pm = ir.process_managers.first
    expect(pm.starts_on).to eq("WidgetMade")
    expect(pm.ends_on).to eq("WidgetMade")
  end

  it "dispatches a real migrated corpus reaction end to end — FreezeAccount emits, ReviewOnFreeze reacts" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      InMemoryDomain.load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry.verify!
    runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c1", number: { value: "ACC1" },
                     kind: { name: "current" }, daily_limit: { cents: 100_000 })

    expect do
      runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "ACC1" })
    end.not_to raise_error

    account = registry.repository("Banking", registry.bluebook("Banking").aggregate("Account")).find("ACC1")
    expect(account[:status]).to eq("frozen")
  end
end
