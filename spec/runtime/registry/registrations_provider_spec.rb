require "spec_helper"

# rust/host's event and registration routes read ir.json's `registrations` key
# instead of naming Event.Schedule and Registration.Request. That key is only
# as trustworthy as the `provides "registrations"` row behind it, so the row is
# held to its contract (every key, each naming a real command) and the exporter
# answers nothing for a domain that attaches no such chapter.
RSpec.describe "registrations capability" do
  def event_body
    proc do
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
  end

  def registration_body
    proc do
      identified_by :registration_id
      attribute :registration_id, RegistrationId
      value_object "RegistrationId" do
        attribute :value, String
      end
      command "Request" do
        goal "request"
        attribute :registration_id, RegistrationId
        sets :registration_id
      end
    end
  end

  def registry_with_registrations(provides: nil)
    provides ||= { schedule: "Event.Schedule", request: "Registration.Request" }
    event = event_body
    registration = registration_body
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Bookings" do
        vision "probe"
        supporting
        provides "registrations", **provides
        aggregate "Event", &event
        aggregate "Registration", &registration
      end
    end
    registry
  end

  it "resolves the chapter that provides registrations, whatever it is named" do
    registry = registry_with_registrations

    expect(registry.registrations_provider_for("Bookings").name).to eq("Bookings")
  end

  it "exports the declared verbs qualified, with the event and registration aggregates named off them" do
    registry = registry_with_registrations

    expect(Hecks::Projector::Exporter.registrations(registry, "Bookings")).to eq(
      provider:               "Bookings",
      schedule:               "Bookings::Event.Schedule",
      request:                "Bookings::Registration.Request",
      event_aggregate:        "Bookings::Event",
      registration_aggregate: "Bookings::Registration"
    )
  end

  it "exports nothing for a domain that attaches no registrations provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.registrations(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_registrations(provides: { schedule: "Event.Schedule" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /registrations needs exactly/)
  end

  it "refuses a provides row whose verb names no command the chapter declares" do
    expect { registry_with_registrations(provides: { schedule: "Event.Schedule", request: "Registration.Ask" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Registration\.Ask/)
  end
end
