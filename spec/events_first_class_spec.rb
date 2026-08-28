require "spec_helper"

# ADR 0025, S6 — "events first-class". Scope-narrowed pass, 2026-08-27:
# `emits`/`on` accept a bare event constant (`emits Account::AccountFrozen`,
# `on Account::AccountFrozen`), resolved the same way `trigger`/`dispatch`
# already resolve a command reference (`Naming.event_ref`, ConstShim).
# UNLIKE command references, the old quoted-string form is NOT refused —
# only command references were 100% corpus-migrated, so refusing the old
# spelling for events would break every live site this pass didn't touch.
# Both forms stay admitted; see policy.bluebook's own KeywordSeed comment.
RSpec.describe "events first-class (ADR 0025, S6)" do
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
    ir = Hecks::Bluebook::DSL::BluebookBuilder.build("EventsBareOn") do
      vision "a bare event constant on `on` resolves the same as a quoted qualified string"

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
    expect do
      Hecks::Bluebook::DSL::BluebookBuilder.build("EventsWithSpecStillChecked") do
        vision "with: is still checked against the triggering event's real shape, bare constant or not"

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

    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "ACC1" },
                     kind: { name: "current" }, daily_limit: { cents: 100_000 })

    expect do
      runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "ACC1" })
    end.not_to raise_error

    account = registry.repository("Banking", registry.bluebook("Banking").aggregate("Account")).find("ACC1")
    expect(account[:status]).to eq("frozen")
  end
end
