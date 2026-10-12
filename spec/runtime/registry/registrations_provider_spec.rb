require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host's event and registration routes read ir.json's `registrations` key
# instead of naming Event.Schedule and Registration.Request. That key is only
# as trustworthy as the `provides "registrations"` row behind it, so the row is
# held to its contract (every key, each naming a real command) and the exporter
# answers nothing for a domain that attaches no such chapter.
RSpec.describe "registrations capability" do
  BOOKINGS_EVENT_BODY = proc do
    identified_by :slug
    attribute :slug, Slug
    value_object "Slug" do
      attribute :value, String
    end
    command "Schedule" do
      goal "schedule"
      attribute :slug, Slug
      sets :slug
    end
  end

  BOOKINGS_REGISTRATION_BODY = proc do
    identified_by :registration_id
    attribute :registration_id, RegistrationId
    attribute :requested_at, RegistrationId, optional: true
    value_object "RegistrationId" do
      attribute :value, String
    end
    command "Request" do
      goal "request"
      attribute :registration_id, RegistrationId
      sets :registration_id
    end
  end

  BOOKINGS_EXPORT = {
    provider:               "Bookings",
    schedule:               "Bookings::Event.Schedule",
    request:                "Bookings::Registration.Request",
    event_aggregate:        "Bookings::Event",
    registration_aggregate: "Bookings::Registration"
  }.freeze

  # A registration whose lifecycle marks the states that give a seat back.
  FREEING_REGISTRATION_BODY = proc do
    instance_exec(&BOOKINGS_REGISTRATION_BODY)
    lifecycle :status, default: "active" do
      mark :frees_seat, "archived", "cancelled"
      transition "Archive" => "archived",  from: "active"
      transition "Cancel"  => "cancelled", from: "active"
    end
    command("Archive") { reference_to Registration }
    command("Cancel") { reference_to Registration }
  end

  def bookings_chapter(provides, registration_body)
    Hecks.bluebook "Bookings" do
      vision "probe"
      supporting
      provides "registrations", **provides
      aggregate "Event", &BOOKINGS_EVENT_BODY
      aggregate "Registration", &registration_body
    end
  end

  def registry_with_registrations(provides: { schedule: "Event.Schedule", request: "Registration.Request" },
                                  body: BOOKINGS_REGISTRATION_BODY)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      bookings_chapter(provides, body)
    end
    registry
  end

  def freeing_row(mark = "Registration.frees_seat")
    { schedule: "Event.Schedule", request: "Registration.Request", frees_seat: mark }
  end

  it "resolves the chapter that provides registrations, whatever it is named" do
    registry = registry_with_registrations

    expect(registry.registrations_provider_for("Bookings").name).to eq("Bookings")
  end

  it "exports the declared verbs qualified, with the event and registration aggregates named off them" do
    exported = Hecks::Projector::Exporter.registrations(registry_with_registrations, "Bookings")

    expect(exported).to eq(BOOKINGS_EXPORT)
  end

  it "exports nothing for a domain that attaches no registrations provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.registrations(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_registrations(provides: { schedule: "Event.Schedule" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /registrations needs schedule, request and may add registered_at/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    expect { registry_with_registrations(provides: { schedule: "Event.Schedule", request: "Registration.Ask" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Registration\.Ask/)
  end

  context "with an optional registered_at attribute" do
    it "exports the name of the attribute the registration is stamped by" do
      registry = registry_with_registrations(
        provides: { schedule: "Event.Schedule", request: "Registration.Request", registered_at: "Registration.requested_at" }
      )

      expect(Hecks::Projector::Exporter.registrations(registry, "Bookings"))
        .to eq(BOOKINGS_EXPORT.merge(registered_at: "requested_at"))
    end

    it "refuses an attribute the aggregate does not declare" do
      expect do
        registry_with_registrations(
          provides: { schedule: "Event.Schedule", request: "Registration.Request", registered_at: "Registration.stamped" }
        )
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /Registration\.stamped.*no attribute/)
    end
  end

  context "with an optional frees_seat mark" do
    it "exports the states of the lifecycle mark it names" do
      registry = registry_with_registrations(provides: freeing_row, body: FREEING_REGISTRATION_BODY)

      expect(Hecks::Projector::Exporter.registrations(registry, "Bookings"))
        .to eq(BOOKINGS_EXPORT.merge(frees_seat: %w[archived cancelled]))
    end

    it "leaves the export unchanged when the row is not declared" do
      registry = registry_with_registrations(body: FREEING_REGISTRATION_BODY)

      expect(Hecks::Projector::Exporter.registrations(registry, "Bookings")).to eq(BOOKINGS_EXPORT)
    end

    it "refuses a mark the aggregate's lifecycle does not declare" do
      expect { registry_with_registrations(provides: freeing_row("Registration.gone"), body: FREEING_REGISTRATION_BODY) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /Registration\.gone.*no lifecycle mark/)
    end

    it "refuses a mark on an aggregate that has no lifecycle" do
      expect { registry_with_registrations(provides: freeing_row) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /Registration\.frees_seat.*no lifecycle mark/)
    end
  end
end
