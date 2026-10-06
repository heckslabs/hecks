require "hecks"
require "hecks/fuzzing/isolated_boot"

# Integration layer between verified OIDC claims and an authorized dispatch.
# Token verification (redirect, code exchange, JWKS) is out of scope; tests start from claims.
RSpec.describe "the OIDC client projection's integration layer" do
  def runtime
    Hecks::Fuzzing::IsolatedBoot.call("examples/banking") { |copy| return Hecks.boot(copy) }
  end

  let(:business) { runtime }
  let!(:customer) { register_customer(business) }

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

  # An identity "id-1" linked to the (issuer, subject) pairs, holding the officer role unless `granted` is false.
  def identity_linked_to(*pairs, granted: true)
    identity = register_identity(business, identity_id: "id-1")
    pairs.each do |issuer, subject|
      link_external(business, identity_id: identity.instance.id, key: "#{issuer}:#{subject}", issuer: issuer, subject: subject)
    end
    grant(business, actor: identity.instance.id, role: "Compliance officer") if granted
    identity
  end

  def as_officer(issuer, subject, &block)
    authenticated_dispatch(business.registry, issuer: issuer, subject: subject, role: "Compliance officer", &block)
  end

  def suspend(customer)
    business.dispatch_flat("Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" })
  end

  def reinstate(customer) = business.dispatch_flat("Banking::Customer.Reinstate", id: customer.instance.id)

  def standing_of(customer)
    aggregate = business.registry.bluebook("Banking").aggregate("Customer")
    business.registry.repository("Banking", aggregate).find(customer.instance.id).state[:standing][:value]
  end

  it "resolves a verified (issuer, subject), checks the role, and dispatches — the full path" do
    identity_linked_to(%w[google sub-1])

    result = as_officer("google", "sub-1") { suspend(customer) }

    expect(result.events.map(&:name)).to eq(["CustomerSuspended"])
  end

  it "refuses before any dispatch when the (issuer, subject) resolves to no linked identity", :aggregate_failures do
    expect { as_officer("google", "forged") { nil } }.to raise_error(/unknown identity/)
    expect(standing_of(customer)).to eq("good")
  end

  it "refuses before any dispatch when the resolved identity holds no matching role", :aggregate_failures do
    identity_linked_to(%w[google sub-1], granted: false)

    expect { as_officer("google", "sub-1") { nil } }.to raise_error(/not authorized/)
    expect(standing_of(customer)).to eq("good")
  end

  it "lets more than one external identifier authenticate as the same identity" do
    identity_linked_to(%w[google sub-1], %w[microsoft sub-1])
    via_google = as_officer("google", "sub-1") { suspend(customer) }
    via_microsoft = as_officer("microsoft", "sub-1") { reinstate(customer) }

    expect([via_google, via_microsoft].map { |result| result.events.map(&:name) })
      .to eq([["CustomerSuspended"], ["CustomerReinstated"]])
  end

  it "stores no password anywhere in Identity or ExternalIdentifier", :aggregate_failures do
    bluebook = business.registry.bluebook("Identity")

    expect(bluebook.aggregate("Identity").attributes.map(&:name)).to eq([:identity_id])
    expect(bluebook.aggregate("ExternalIdentifier").attributes.map(&:name))
      .to eq(%i[identity key issuer subject])
  end
end
