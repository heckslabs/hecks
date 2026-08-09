require "hecksagain"
require "hecksagain/fuzzing/isolated_boot"

# §11'S INTEGRATION LAYER — everything BETWEEN a verified OIDC token and
# an authorized dispatch. What "verified" means (redirect, code exchange,
# JWT/JWKS signature checking against a live provider) is deliberately
# out of scope: real, security-critical, external-dependency work,
# tracked separately. This starts from claims already in hand, exactly
# the plan doc's own sketch:
#
#   identity = identities.lookup_external(issuer: claims["iss"], subject: claims["sub"])
#   Hecks.as_caller(role: governance.role_for(identity)) { runtime.dispatch(...) }
#
# `lookup_external` is `Ports::IdentityResolution.resolve` ; `role_for`
# is folded into the same check `Ports::Authorization.holds_role?`
# already makes for `act_as` — the model here is "does this identity
# hold the ONE role this command needs," not a single role-per-identity
# lookup, since `RoleAssignment` already supports an actor holding
# several roles at once.
#
# THE REAL, SHIPPED WIRING, same as governance_authorization_spec.rb —
# Banking's own `.hecksagon` already declares `uses_framework
# "Governance"` and `uses_framework "Identity"`, so a plain `Hecks.boot`
# has both in the same registry, and `Fuzzing::IsolatedBoot` keeps a
# Heki-backed boot from touching examples/banking/data/ for real.
RSpec.describe "the OIDC client projection's integration layer" do
  def runtime
    Hecksagain::Fuzzing::IsolatedBoot.call("examples/banking") { |copy| return Hecks.boot(copy) }
  end

  let(:business) { runtime }

  def register_customer(runtime, reference: "C-1")
    runtime.dispatch(
      "Banking::Customer.Register",
      reference: { value: reference },
      name: { given: "Dana", family: "Ng" },
      email: { address: "dana@example.com" }
    )
  end

  def register_identity(runtime, identity_id:)
    runtime.dispatch("Identity::Identity.Register", identity_id: { value: identity_id })
  end

  def link_external(runtime, identity_id:, key:, issuer:, subject:)
    runtime.dispatch(
      "Identity::ExternalIdentifier.Link",
      identity_id: identity_id, key: { value: key }, issuer: { value: issuer }, subject: { value: subject }
    )
  end

  def grant(runtime, actor:, role:)
    runtime.dispatch(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Branch-1" }, starts_at: { value: "2026-01-01" }
    )
  end

  # THE APPLICATION-LEVEL COMPOSITION — not new library code, the same
  # discipline `act_as_spec.rb`'s own helper follows: verified claims in,
  # a scoped dispatch out, refusing before the block ever runs if either
  # step says no.
  def authenticated_dispatch(registry, issuer:, subject:, role:)
    identity_id = Hecksagain::Ports::IdentityResolution.resolve(registry, issuer: issuer, subject: subject)
    raise "unknown identity" unless identity_id
    raise "not authorized" unless Hecksagain::Ports::Authorization.holds_role?(registry, actor_id: identity_id, role: role)

    Hecksagain.as_caller(role: role) { yield }
  end

  it "resolves a verified (issuer, subject), checks the role, and dispatches — the full path" do
    customer = register_customer(business)
    identity = register_identity(business, identity_id: "id-1")
    link_external(business, identity_id: identity.instance.id, key: "google:sub-1", issuer: "google", subject: "sub-1")
    grant(business, actor: identity.instance.id, role: "Compliance officer")

    result = authenticated_dispatch(business.registry, issuer: "google", subject: "sub-1", role: "Compliance officer") do
      business.dispatch("Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" })
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
      business.dispatch("Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" })
    end
    via_microsoft = authenticated_dispatch(business.registry, issuer: "microsoft", subject: "sub-1", role: "Compliance officer") do
      business.dispatch("Banking::Customer.Reinstate", id: customer.instance.id)
    end

    expect(via_google.events.map(&:name)).to eq(["CustomerSuspended"])
    expect(via_microsoft.events.map(&:name)).to eq(["CustomerReinstated"])
  end

  it "stores no password anywhere in Identity or ExternalIdentifier" do
    bluebook = business.registry.bluebook("Identity")

    expect(bluebook.aggregate("Identity").attributes.map(&:name)).to eq([:identity_id])
    expect(bluebook.aggregate("ExternalIdentifier").attributes.map(&:name))
      .to eq(%i[identity_id key issuer subject])
  end
end
