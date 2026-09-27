require "hecks"
require "hecks/fuzzing/isolated_boot"

# Integration layer between verified OIDC claims and an authorized dispatch.
# Token verification (redirect, code exchange, JWKS) is out of scope; tests start from claims.
RSpec.describe "the OIDC client projection's integration layer" do
  def runtime
    Hecks::Fuzzing::IsolatedBoot.call("examples/banking") { |copy| return Hecks.boot(copy) }
  end

  let(:business) { runtime }

  def register_customer(runtime, reference: "C-1")
    runtime.dispatch_flat(
      "Banking::Customer.Register",
      reference: { value: reference },
      name:      { given: "Dana", family: "Ng" },
      email:     { address: "dana@example.com" }
    )
  end

  def register_identity(runtime, identity_id:)
    runtime.dispatch_flat("Identity::Identity.Register", identity_id: { value: identity_id })
  end

  def link_external(runtime, identity_id:, key:, issuer:, subject:)
    runtime.dispatch_flat(
      "Identity::ExternalIdentifier.Link",
      identity: identity_id, key: { value: key }, issuer: { value: issuer }, subject: { value: subject }
    )
  end

  def grant(runtime, actor:, role:)
    runtime.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Branch-1" }, starts_at: { value: "2026-01-01" }
    )
  end

  # Application-level composition: verified claims in, scoped dispatch out, refused up front.
  def authenticated_dispatch(registry, issuer:, subject:, role:, &block)
    identity_id = Hecks::Ports::IdentityResolution.resolve(registry, issuer: issuer, subject: subject)
    raise "unknown identity" unless identity_id
    raise "not authorized" unless Hecks::Ports::Authorization.holds_role?(registry, actor_id: identity_id, role: role)

    Hecks.as_caller(role: role, &block)
  end

  it "resolves a verified (issuer, subject), checks the role, and dispatches — the full path" do
    customer = register_customer(business)
    identity = register_identity(business, identity_id: "id-1")
    link_external(business, identity_id: identity.instance.id, key: "google:sub-1", issuer: "google", subject: "sub-1")
    grant(business, actor: identity.instance.id, role: "Compliance officer")

    result = authenticated_dispatch(business.registry, issuer: "google", subject: "sub-1", role: "Compliance officer") do
      business.dispatch_flat("Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" })
    end

    expect(result.events.map(&:name)).to eq(["CustomerSuspended"])
  end

  it "refuses before any dispatch when the (issuer, subject) resolves to no linked identity" do
    customer = register_customer(business)

    expect { authenticated_dispatch(business.registry, issuer: "google", subject: "forged", role: "Compliance officer") {} }
      .to raise_error(/unknown identity/)

    expect(business.registry.repository("Banking", business.registry.bluebook("Banking").aggregate("Customer"))
      .find(customer.instance.id).state[:standing][:value]).to eq("good")
  end

  it "refuses before any dispatch when the resolved identity holds no matching role" do
    customer = register_customer(business)
    identity = register_identity(business, identity_id: "id-1")
    link_external(business, identity_id: identity.instance.id, key: "google:sub-1", issuer: "google", subject: "sub-1")
    # No RoleAssignment granted at all.

    expect { authenticated_dispatch(business.registry, issuer: "google", subject: "sub-1", role: "Compliance officer") {} }
      .to raise_error(/not authorized/)

    expect(business.registry.repository("Banking", business.registry.bluebook("Banking").aggregate("Customer"))
      .find(customer.instance.id).state[:standing][:value]).to eq("good")
  end

  it "lets more than one external identifier authenticate as the same identity" do
    customer = register_customer(business)
    identity = register_identity(business, identity_id: "id-1")
    link_external(business, identity_id: identity.instance.id, key: "google:sub-1", issuer: "google", subject: "sub-1")
    link_external(business, identity_id: identity.instance.id, key: "microsoft:sub-1", issuer: "microsoft", subject: "sub-1")
    grant(business, actor: identity.instance.id, role: "Compliance officer")

    via_google = authenticated_dispatch(business.registry, issuer: "google", subject: "sub-1", role: "Compliance officer") do
      business.dispatch_flat("Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" })
    end
    via_microsoft = authenticated_dispatch(business.registry, issuer: "microsoft", subject: "sub-1",
role: "Compliance officer") do
      business.dispatch_flat("Banking::Customer.Reinstate", id: customer.instance.id)
    end

    expect(via_google.events.map(&:name)).to eq(["CustomerSuspended"])
    expect(via_microsoft.events.map(&:name)).to eq(["CustomerReinstated"])
  end

  it "stores no password anywhere in Identity or ExternalIdentifier" do
    bluebook = business.registry.bluebook("Identity")

    expect(bluebook.aggregate("Identity").attributes.map(&:name)).to eq([:identity_id])
    expect(bluebook.aggregate("ExternalIdentifier").attributes.map(&:name))
      .to eq(%i[identity key issuer subject])
  end
end
