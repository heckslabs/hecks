require "hecks"

# A local boot, not `boot_in_memory` — that helper is Pizzas-specific by
# design (spec_helper.rb's own comment). Same shape, Governance's own
# bluebook/hecksagon, Memory regardless of what a real deployment would
# bind — the established rule for specs (see feedback memory on this).
RSpec.describe "Governance" do
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/governance.bluebook"))
      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  def assign(actor: "u-1", role: "Teller", scope: "Branch-1", starts_at: "2026-01-01")
    runtime.dispatch(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: scope }, starts_at: { value: starts_at }
    )
  end

  it "assigns a role, identified by actor, role, and when it started" do
    result = assign

    expect(result.events.map(&:name)).to eq(["RoleAssigned"])
    expect(result.instance.id).to eq("u-1:Teller:2026-01-01")
    expect(result.instance.state[:ends_at]).to be_nil
  end

  it "treats a second assignment of the same actor/role at a different starts_at as a distinct record" do
    first  = assign(starts_at: "2026-01-01")
    second = assign(starts_at: "2026-06-01")

    expect(first.instance.id).not_to eq(second.instance.id)
    expect(runtime.query("Governance::RoleAssignment.AssignmentsForActor", actor_id: { value: "u-1" }).size).to eq(2)
  end

  it "revokes by setting ends_at, without deleting the record" do
    created = assign
    result  = runtime.dispatch("Governance::RoleAssignment.Revoke", id: created.instance.id, ends_at: { value: "2026-05-31" })

    expect(result.events.map(&:name)).to eq(["RoleRevoked"])
    expect(result.instance.state[:ends_at][:value]).to eq("2026-05-31")
    expect(runtime.query("Governance::RoleAssignment.AssignmentsForActor", actor_id: { value: "u-1" }).size).to eq(1)
  end

  it "AssignmentsForActor returns a revoked assignment too — filtering by ends_at is the caller's decision" do
    created = assign
    runtime.dispatch("Governance::RoleAssignment.Revoke", id: created.instance.id, ends_at: { value: "2026-05-31" })

    rows = runtime.query("Governance::RoleAssignment.AssignmentsForActor", actor_id: { value: "u-1" })
    expect(rows.map { |row| row[:id] }).to eq(["u-1:Teller:2026-01-01"])
  end

  def grant(from: "Customer administrator", to: "Customer registrar")
    runtime.dispatch(
      "Governance::RoleTransition.Grant",
      from_role: { value: from }, to_role: { value: to }
    )
  end

  it "grants a role transition, identified by the (from, to) pair" do
    result = grant

    expect(result.events.map(&:name)).to eq(["RoleTransitionGranted"])
    expect(result.instance.id).to eq("Customer administrator:Customer registrar")
    expect(result.instance.state[:ends_at]).to be_nil
  end

  it "revokes a role transition by setting ends_at, without deleting the record" do
    created = grant
    result  = runtime.dispatch("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-05-31" })

    expect(result.events.map(&:name)).to eq(["RoleTransitionRevoked"])
    expect(result.instance.state[:ends_at][:value]).to eq("2026-05-31")
  end

  it "Allowed finds the exact pair, and only that pair" do
    grant

    matching = runtime.query(
      "Governance::RoleTransition.Allowed",
      from_role: { value: "Customer administrator" }, to_role: { value: "Customer registrar" }
    )
    reversed = runtime.query(
      "Governance::RoleTransition.Allowed",
      from_role: { value: "Customer registrar" }, to_role: { value: "Customer administrator" }
    )

    expect(matching.map { |row| row[:id] }).to eq(["Customer administrator:Customer registrar"])
    expect(reversed).to be_empty
  end

  it "Allowed still returns a revoked transition — the caller reads ends_at, same as RoleAssignment" do
    created = grant
    runtime.dispatch("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-05-31" })

    rows = runtime.query(
      "Governance::RoleTransition.Allowed",
      from_role: { value: "Customer administrator" }, to_role: { value: "Customer registrar" }
    )

    expect(rows.size).to eq(1)
    expect(rows.first[:ends_at][:value]).to eq("2026-05-31")
  end
end
