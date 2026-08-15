require "spec_helper"

# `role` used to be pure decoration — declared, stored, read by nothing at
# dispatch time. This holds the fix: opt-in on both sides (no caller bound,
# or a command with no declared role, both dispatch exactly as before), and
# a real refusal once a caller states a role and it doesn't match.
RSpec.describe "role-based command rejections" do
  def build(&block)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/authorization.port", __dir__))
      Kernel.load(File.expand_path("../../lib/hecksagain/adapters/driven/governance_authorization.adapter", __dir__))
      Hecks.bluebook("Cafeteria", &block)
      Hecks.hecksagon("Cafeteria") do
        uses_framework "Governance"
        Cafeteria::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  CAFETERIA_DOMAIN = proc do
    vision "An order, placed and prepared."
    generic

    aggregate "Order" do
      identified_by :ref
      attribute :ref, OrderRef
      value_object "OrderRef" do
        attribute :value, String
      end

      command "Place" do
        role "Customer"
        attribute :ref, OrderRef
        emits "OrderPlaced"
      end

      command "Prepare" do
        role "Chef"
        reference_to Order
        emits "OrderPrepared"
      end

      command "Cancel" do
        reference_to Order
        emits "OrderCancelled"
      end
    end

    policy "StartPrep" do
      on      "OrderPlaced"
      trigger Order::Prepare
    end
  end

  it "dispatches unchanged when no caller is bound" do
    build(&CAFETERIA_DOMAIN)
    order = Order.place(ref: { value: "o1" })
    expect(order.events.map(&:name)).to include("OrderPlaced")
  end

  it "dispatches when the bound caller's role matches the command's" do
    build(&CAFETERIA_DOMAIN)
    Hecksagain.as_caller(role: "Customer") do
      order = Order.place(ref: { value: "o1" })
      expect(order.events.map(&:name)).to include("OrderPlaced")
    end
  end

  it "refuses when the bound caller's role does not match" do
    build(&CAFETERIA_DOMAIN)
    expect {
      Hecksagain.as_caller(role: "Chef") { Order.place(ref: { value: "o1" }) }
    }.to raise_error(Hecksagain::Runtime::Unauthorized, /refused — role: Customer, and the caller stated Chef/)
  end

  it "dispatches unchanged when the command declares no role at all" do
    build(&CAFETERIA_DOMAIN)
    order = Order.place(ref: { value: "o1" })
    Hecksagain.as_caller(role: "Anyone At All") { order.cancel }
    expect(order.events.last.name).to eq("OrderCancelled")
  end

  it "restores the outer binding once a nested as_caller block exits" do
    build(&CAFETERIA_DOMAIN)
    Hecksagain.as_caller(role: "Customer") do
      Hecksagain.as_caller(role: "Chef") do
        expect(Hecksagain::Runtime::Caller.current.role).to eq("Chef")
      end
      expect(Hecksagain::Runtime::Caller.current.role).to eq("Customer")
    end
    expect(Hecksagain::Runtime::Caller.current).to be_nil
  end

  it "does not carry the triggering caller's role into a policy's reaction command" do
    runtime = build(&CAFETERIA_DOMAIN)
    Hecksagain.as_caller(role: "Customer") { Order.place(ref: { value: "o1" }) }

    reaction = runtime.reactions.first
    expect(reaction[:delivered]).to eq(true)
    expect(Order.find("o1").events.map(&:name)).to include("OrderPrepared")
  end

  # THE REAL CHECK — once Governance is attached (every hecksagon above
  # now carries `uses_framework "Governance"`, the new declare-time
  # requirement), a caller who ALSO names WHO they are is checked
  # against a real `RoleAssignment`, not the string they happened to
  # type. `role:` and `actor_id:` disagreeing is the case that proves
  # identity wins: a caller cannot talk its way past a role it was never
  # granted just by typing the right word.
  describe "an identified caller, checked against a real Governance grant" do
    def grant(runtime, actor_id:, role_name:)
      runtime.dispatch("Governance::RoleAssignment.Assign",
                        actor_id: { value: actor_id }, role_name: { value: role_name },
                        scope: { value: "kitchen" }, starts_at: { value: "2026-01-01" })
    end

    it "dispatches when the actor holds the command's role via a real assignment" do
      runtime = build(&CAFETERIA_DOMAIN)
      grant(runtime, actor_id: "u1", role_name: "Chef")
      Hecksagain.as_caller(role: "Customer") { Order.place(ref: { value: "o1" }) }
      order = Order.find("o1")

      Hecksagain.as_caller(role: "Chef", actor_id: "u1") { order.prepare }
      expect(order.events.map(&:name)).to include("OrderPrepared")
    end

    it "refuses an identified caller with no matching grant, even though the role it typed matches" do
      runtime = build(&CAFETERIA_DOMAIN)
      Hecksagain.as_caller(role: "Customer") { Order.place(ref: { value: "o1" }) }
      order = Order.find("o1")

      expect {
        Hecksagain.as_caller(role: "Chef", actor_id: "u2") { order.prepare }
      }.to raise_error(Hecksagain::Runtime::Unauthorized, /refused — role: Chef, and the caller stated Chef/)
    end

    it "refuses an identified caller whose real assignment is for a different role" do
      runtime = build(&CAFETERIA_DOMAIN)
      grant(runtime, actor_id: "u3", role_name: "Customer")
      Hecksagain.as_caller(role: "Customer", actor_id: "u3") { Order.place(ref: { value: "o1" }) }
      order = Order.find("o1")

      expect {
        Hecksagain.as_caller(role: "Chef", actor_id: "u3") { order.prepare }
      }.to raise_error(Hecksagain::Runtime::Unauthorized)
    end
  end
end
