require "hecksagain"

# THE SAME-REGISTRY CASE. Banking and Governance loaded into ONE boot, so
# `GovernanceAuthorization` needs no bridge to a second runtime — it just
# dispatches a query against records already sitting in the registry it is
# handed. This is the shape `spec/act_as_spec.rb` deliberately did NOT use
# (two separate registries, for Governance/RoleTransition's own reasons) —
# a same-registry app gets to skip that coordination entirely. Covers both
# halves the port answers: `holds_role?` (RoleAssignment) and
# `authorized_as?` (RoleTransition) — the latter proved end to end as an
# `act_as` flow through the port, the same shape `act_as_spec.rb` proves
# by querying Governance directly.
RSpec.describe Hecksagain::Adapters::GovernanceAuthorization do
  def banking_bluebook
    File.expand_path("../../../examples/banking/bluebook/banking.bluebook", __dir__)
  end

  def governance_bluebook
    File.expand_path("../../../framework/bluebook/governance.bluebook", __dir__)
  end

  def authorization_port
    File.expand_path("../../../lib/hecksagain/ports/authorization.port", __dir__)
  end

  def governance_adapter
    File.expand_path("../../../lib/hecksagain/adapters/driven/governance_authorization.adapter", __dir__)
  end

  def runtime
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(authorization_port)
      Kernel.load(governance_adapter)
      Kernel.load(governance_bluebook)
      Kernel.load(banking_bluebook)

      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
      Hecks.hecksagon("Banking") { ::Banking::Customer.persisted_by("Memory") }
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
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

  def assign(runtime, actor:, role:)
    runtime.dispatch(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Branch-1" }, starts_at: { value: "2026-01-01" }
    )
  end

  def grant_transition(runtime, from:, to:)
    runtime.dispatch(
      "Governance::RoleTransition.Grant",
      from_role: { value: from }, to_role: { value: to }
    )
  end

  it "answers true for an actor who currently holds the role" do
    assign(business, actor: "officer-1", role: "Compliance officer")

    expect(
      described_class.holds_role?(business.registry, actor_id: "officer-1", role: "Compliance officer")
    ).to be(true)
  end

  it "answers false for an actor with no assignment at all" do
    expect(
      described_class.holds_role?(business.registry, actor_id: "nobody", role: "Compliance officer")
    ).to be(false)
  end

  it "answers false once the assignment is revoked" do
    created = assign(business, actor: "officer-1", role: "Compliance officer")
    business.dispatch("Governance::RoleAssignment.Revoke", id: created.instance.id, ends_at: { value: "2026-02-01" })

    expect(
      described_class.holds_role?(business.registry, actor_id: "officer-1", role: "Compliance officer")
    ).to be(false)
  end

  it "gates a real role-checked Banking dispatch, end to end through the port" do
    customer = register_customer(business)
    assign(business, actor: "officer-1", role: "Compliance officer")

    allowed = Hecksagain::Ports::Authorization.holds_role?(
      business.registry, actor_id: "officer-1", role: "Compliance officer"
    )
    expect(allowed).to be(true)

    result = Hecksagain.as_caller(role: "Compliance officer") do
      business.dispatch(
        "Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" }
      )
    end

    expect(result.events.map(&:name)).to eq(["CustomerSuspended"])
  end

  it "the app-level check refuses before any dispatch, when the port says no" do
    customer = register_customer(business)

    allowed = Hecksagain::Ports::Authorization.holds_role?(
      business.registry, actor_id: "nobody", role: "Compliance officer"
    )
    expect(allowed).to be(false)

    # Never reached in a real app — no `as_caller`, no dispatch. Proved
    # here by dispatching UNAUTHENTICATED (no caller bound at all), which
    # `CommandRules::Authorization` itself would let through since a role
    # check is inert with no ambient caller — the port's "no" is what has
    # to stop the app from ever getting here, not the runtime.
    expect(business.registry.repository("Banking", business.registry.bluebook("Banking").aggregate("Customer"))
      .find(customer.instance.id).state[:standing][:value]).to eq("good")
  end

  describe "#authorized_as? — the RoleTransition half" do
    it "answers true for a granted transition" do
      grant_transition(business, from: "Branch clerk", to: "Compliance officer")

      expect(
        described_class.authorized_as?(business.registry, from_role: "Branch clerk", to_role: "Compliance officer")
      ).to be(true)
    end

    it "answers false with no grant at all" do
      expect(
        described_class.authorized_as?(business.registry, from_role: "Branch clerk", to_role: "Compliance officer")
      ).to be(false)
    end

    it "answers false once the grant is revoked" do
      created = grant_transition(business, from: "Branch clerk", to: "Compliance officer")
      business.dispatch("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-02-01" })

      expect(
        described_class.authorized_as?(business.registry, from_role: "Branch clerk", to_role: "Compliance officer")
      ).to be(false)
    end
  end

  it "act_as through the port: a granted transition lets one role act as another, then restores" do
    grant_transition(business, from: "Branch clerk", to: "Compliance officer")
    customer = register_customer(business)

    Hecksagain.as_caller(role: "Branch clerk") do
      allowed = Hecksagain::Ports::Authorization.authorized_as?(
        business.registry, from_role: "Branch clerk", to_role: "Compliance officer"
      )
      expect(allowed).to be(true)

      suspended = Hecksagain.as_caller(role: "Compliance officer") do
        business.dispatch(
          "Banking::Customer.Suspend", id: customer.instance.id, standing: { value: "suspended" }
        )
      end
      expect(suspended.events.map(&:name)).to eq(["CustomerSuspended"])

      # RESTORED. Still inside the OUTER as_caller, no nested block in the
      # way — "Branch clerk" is authorized for Register, so this only
      # succeeds if the role actually went back.
      registered = register_customer(business, reference: "C-2")
      expect(registered.events.map(&:name)).to eq(["CustomerRegistered"])
    end
  end
end
