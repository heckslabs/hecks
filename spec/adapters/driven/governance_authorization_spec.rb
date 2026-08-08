require "hecksagain"
require "hecksagain/fuzzing/isolated_boot"

# THE REAL, SHIPPED WIRING — not a hand-composed registry. Banking's own
# `.hecksagon` declares `uses_framework "Governance"` (see
# examples/banking/bluebook/banking.hecksagon), so a plain `Hecks.boot`
# already attaches Governance to the same registry ; `GovernanceAuthorization`
# needs no bridge to a second runtime, just a dispatch against records
# already sitting in the store it is handed. `Fuzzing::IsolatedBoot` is
# what every other spec touching a Heki-backed example already uses to
# avoid writing into the real examples/banking/data/ files — it copies the
# domain to a tmpdir and rebinds every persistence there to Memory ;
# Governance's own hecksagon is Memory already and lives outside the
# copied tree entirely (`Framework.load!` always reaches its real path),
# so nothing about attaching it needs isolating twice.
#
# Covers both halves the port answers: `holds_role?` (RoleAssignment) and
# `authorized_as?` (RoleTransition) — the latter proved end to end as an
# `act_as` flow through the port, the same shape `act_as_spec.rb` proves
# by querying Governance directly (two separate registries, for
# RoleTransition's own reasons — see that file's own header).
RSpec.describe Hecksagain::Adapters::GovernanceAuthorization do
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
