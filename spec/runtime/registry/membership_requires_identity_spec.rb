require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host sign-in needs both the membership and identity keys, so verify! refuses
# Membership without Identity before project_rust can emit a half-wired IR.
RSpec.describe "membership requires identity" do
  MEMBERSHIP_PROBE_DOMAIN = proc do
    vision "probe"
    supporting
    provides "membership",
             admit:  "Person.Admit",
             grant:  "Person.GrantAccess",
             people: "Person.All"
    aggregate "Person" do
      identified_by :email
      attribute :email, Email
      value_object "Email" do
        attribute :value, String
      end
      command "Admit" do
        goal "admit"
        attribute :email, Email
        sets :email
      end
      command "GrantAccess" do
        goal "grant"
        reference_to Person
      end
      query "All" do
        description "all"
      end
    end
  end

  def registry_with_membership(also_identity: false)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.bluebook("Membership", &MEMBERSHIP_PROBE_DOMAIN)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/identity.bluebook")) if also_identity
    end
    registry
  end

  it "refuses a membership chapter with no identity chapter" do
    expect { registry_with_membership.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /provides "identity"/)
  end

  it "boots when both membership and identity chapters are loaded" do
    expect { registry_with_membership(also_identity: true).verify! }.not_to raise_error
  end
end
