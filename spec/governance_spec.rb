require "hecks"

# A local boot rather than `boot_in_memory`, which is Pizzas-specific; Memory-persisted.
RSpec.describe "Governance" do
  def load_governance
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/governance.bluebook")]
      .each { |file| Kernel.load(file) }
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) { load_governance }

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  def assign(actor: "u-1", role: "Teller", scope: "Branch-1", starts_at: "2026-01-01")
    runtime.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: scope }, starts_at: { value: starts_at }
    )
  end

  # Ends the record `created` stands for, on either aggregate.
  def revoke(aggregate, created)
    runtime.dispatch_flat("Governance::#{aggregate}.Revoke", id: created.instance.id, ends_at: { value: "2026-05-31" })
  end

  def assignments_for(actor)
    runtime.query("Governance::RoleAssignment.AssignmentsForActor", actor_id: { value: actor })
  end

  it "assigns a role, identified by actor, role, and when it started", :aggregate_failures do
    result = assign

    expect(result.events.map(&:name)).to eq(["RoleAssigned"])
    expect(result.instance.id).to eq("u-1:Teller:2026-01-01")
    expect(result.instance.state[:ends_at]).to be_nil
  end

  it "treats a second assignment of the same actor/role at a different starts_at as a distinct record", :aggregate_failures do
    first  = assign(starts_at: "2026-01-01")
    second = assign(starts_at: "2026-06-01")

    expect(first.instance.id).not_to eq(second.instance.id)
    expect(assignments_for("u-1").size).to eq(2)
  end

  it "revokes by setting ends_at, without deleting the record", :aggregate_failures do
    result = revoke("RoleAssignment", assign)

    expect(result.events.map(&:name)).to eq(["RoleRevoked"])
    expect(result.instance.state[:ends_at][:value]).to eq("2026-05-31")
    expect(assignments_for("u-1").size).to eq(1)
  end

  it "AssignmentsForActor returns a revoked assignment too — filtering by ends_at is the caller's decision" do
    revoke("RoleAssignment", assign)

    expect(assignments_for("u-1").map { |row| row[:id] }).to eq(["u-1:Teller:2026-01-01"])
  end

  # Regression: a nil value-object query argument must raise TypeMismatch like a command
  # argument does (C3.7, docs/semantics/bluebook-semantics.md), not return an empty row set.
  it "refuses AssignmentsForActor's actor_id offered as nil, exactly as a command argument would" do
    expect { runtime.query("Governance::RoleAssignment.AssignmentsForActor", actor_id: nil) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /IdentityId\.value expects String, got nil/)
  end

  # C3.8 carve-out: a bare-scalar query argument stays untyped. No such argument exists in this
  # bluebook, so the private `checked_vo?` guard is pinned directly through `send`.
  it "checked_vo? only ever fires for a nil, non-optional, value-object-typed query attribute", :aggregate_failures do
    interpreter = Hecks::Runtime::QueryInterpreter.new(runtime.registry)
    aggregate = runtime.registry.bluebook("Governance").aggregate("RoleAssignment")
    actor_id_attribute = aggregate.query("AssignmentsForActor").attributes.find { |a| a.name == :actor_id }

    expect(interpreter.send(:checked_vo?, aggregate, actor_id_attribute, nil)).to be(true)
    expect(interpreter.send(:checked_vo?, aggregate, actor_id_attribute, { value: "u-1" })).to be(false)
  end

  def grant(from: "Customer administrator", to: "Customer registrar", starts_at: "2026-01-01")
    runtime.dispatch_flat(
      "Governance::RoleTransition.Grant",
      from_role: { value: from }, to_role: { value: to }, starts_at: { value: starts_at }
    )
  end

  def allowed(from, to)
    runtime.query("Governance::RoleTransition.Allowed", from_role: { value: from }, to_role: { value: to })
  end

  def administrator_to_registrar = allowed("Customer administrator", "Customer registrar")

  def registrar_to_administrator = allowed("Customer registrar", "Customer administrator")

  # Grants a pair, revokes it, and grants it again at a later start; returns both grants.
  def regrant_after_revoking
    first = grant(starts_at: "2026-01-01")
    revoke("RoleTransition", first)
    [first, grant(starts_at: "2026-06-01")]
  end

  it "grants a role transition, identified by the (from, to, starts_at) triple", :aggregate_failures do
    result = grant

    expect(result.events.map(&:name)).to eq(["RoleTransitionGranted"])
    expect(result.instance.id).to eq("Customer administrator:Customer registrar:2026-01-01")
    expect(result.instance.state[:ends_at]).to be_nil
  end

  # Regression: `starts_at` is part of the identity, so re-granting a revoked pair creates a new
  # record instead of colliding as `AlreadyExists`.
  it "grants a previously-revoked pair again, as a distinct record — the pair is not an absorbing state", :aggregate_failures do
    first, second = regrant_after_revoking

    expect(second.events.map(&:name)).to eq(["RoleTransitionGranted"])
    expect(second.instance.id).not_to eq(first.instance.id)
    expect(second.instance.state[:ends_at]).to be_nil
  end

  it "keeps both the revoked and the re-granted record readable through Allowed" do
    first, second = regrant_after_revoking

    expect(administrator_to_registrar.map { |row| row[:id] }).to contain_exactly(first.instance.id, second.instance.id)
  end

  it "revokes a role transition by setting ends_at, without deleting the record", :aggregate_failures do
    result = revoke("RoleTransition", grant)

    expect(result.events.map(&:name)).to eq(["RoleTransitionRevoked"])
    expect(result.instance.state[:ends_at][:value]).to eq("2026-05-31")
  end

  it "Allowed finds the exact pair, and only that pair", :aggregate_failures do
    grant

    expect(administrator_to_registrar.map { |row| row[:id] }).to eq(["Customer administrator:Customer registrar:2026-01-01"])
    expect(registrar_to_administrator).to be_empty
  end

  it "Allowed still returns a revoked transition — the caller reads ends_at, same as RoleAssignment", :aggregate_failures do
    revoke("RoleTransition", grant)
    rows = administrator_to_registrar

    expect(rows.size).to eq(1)
    expect(rows.first[:ends_at][:value]).to eq("2026-05-31")
  end
end
