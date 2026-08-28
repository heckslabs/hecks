require "spec_helper"
require "time"

# `role` used to be pure decoration — declared, stored, read by nothing at
# dispatch time. This holds the fix: opt-in on both sides (no caller bound,
# or a command with no declared role, both dispatch exactly as before), and
# a real refusal once a caller states a role and it doesn't match.
RSpec.describe "role-based command rejections" do
  def build(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecks/ports/authorization.port", __dir__))
      Kernel.load(File.expand_path("../../lib/hecks/adapters/driven/governance_authorization.adapter", __dir__))
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
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
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
    order = Order.place!(ref: { value: "o1" })
    expect(order.events.map(&:name)).to include("OrderPlaced")
  end

  it "dispatches when the bound caller's role matches the command's" do
    build(&CAFETERIA_DOMAIN)
    Hecks.as_caller(role: "Customer") do
      order = Order.place!(ref: { value: "o1" })
      expect(order.events.map(&:name)).to include("OrderPlaced")
    end
  end

  it "refuses when the bound caller's role does not match" do
    build(&CAFETERIA_DOMAIN)
    expect {
      Hecks.as_caller(role: "Chef") { Order.place!(ref: { value: "o1" }) }
    }.to raise_error(Hecks::Runtime::Unauthorized, /refused — role: Customer, and the caller stated Chef/)
  end

  it "dispatches unchanged when the command declares no role at all" do
    build(&CAFETERIA_DOMAIN)
    order = Order.place!(ref: { value: "o1" })
    Hecks.as_caller(role: "Anyone At All") { order.cancel! }
    expect(order.events.last.name).to eq("OrderCancelled")
  end

  it "restores the outer binding once a nested as_caller block exits" do
    build(&CAFETERIA_DOMAIN)
    Hecks.as_caller(role: "Customer") do
      Hecks.as_caller(role: "Chef") do
        expect(Hecks::Runtime::Caller.current.role).to eq("Chef")
      end
      expect(Hecks::Runtime::Caller.current.role).to eq("Customer")
    end
    expect(Hecks::Runtime::Caller.current).to be_nil
  end

  it "does not carry the triggering caller's role into a policy's reaction command" do
    runtime = build(&CAFETERIA_DOMAIN)
    Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }

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
      Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
      order = Order.find("o1")

      Hecks.as_caller(role: "Chef", actor_id: "u1") { order.prepare! }
      expect(order.events.map(&:name)).to include("OrderPrepared")
    end

    it "refuses an identified caller with no matching grant, even though the role it typed matches" do
      runtime = build(&CAFETERIA_DOMAIN)
      Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
      order = Order.find("o1")

      expect {
        Hecks.as_caller(role: "Chef", actor_id: "u2") { order.prepare! }
      }.to raise_error(Hecks::Runtime::Unauthorized, /refused — role: Chef, and the caller stated Chef/)
    end

    it "refuses an identified caller whose real assignment is for a different role" do
      runtime = build(&CAFETERIA_DOMAIN)
      grant(runtime, actor_id: "u3", role_name: "Customer")
      Hecks.as_caller(role: "Customer", actor_id: "u3") { Order.place!(ref: { value: "o1" }) }
      order = Order.find("o1")

      expect {
        Hecks.as_caller(role: "Chef", actor_id: "u3") { order.prepare! }
      }.to raise_error(Hecks::Runtime::Unauthorized)
    end

    # `as_of` — OPT-IN on top of `actor_id`, same shape: unbound, the
    # pre-existing behavior (a future-dated `starts_at` authorizes
    # immediately); bound, the real check.
    describe "as_of — a bound assignment's own starts_at" do
      it "dispatches unchanged when as_of is not bound, even for a not-yet-started assignment" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant(runtime, actor_id: "u4", role_name: "Chef")
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        Hecks.as_caller(role: "Chef", actor_id: "u4") { order.prepare! }
        expect(order.events.map(&:name)).to include("OrderPrepared")
      end

      it "refuses an identified caller whose real assignment has not started yet, once as_of is bound" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant(runtime, actor_id: "u5", role_name: "Chef") # starts_at: "2026-01-01"
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        before_start = Time.parse("2025-12-31").to_i
        expect {
          Hecks.as_caller(role: "Chef", actor_id: "u5", as_of: before_start) { order.prepare! }
        }.to raise_error(Hecks::Runtime::Unauthorized)
      end

      it "dispatches when as_of is bound and the assignment has already started" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant(runtime, actor_id: "u6", role_name: "Chef") # starts_at: "2026-01-01"
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        after_start = Time.parse("2026-06-01").to_i
        Hecks.as_caller(role: "Chef", actor_id: "u6", as_of: after_start) { order.prepare! }
        expect(order.events.map(&:name)).to include("OrderPrepared")
      end
    end

    # `scope` — the same opt-in shape again: unbound authorizes against
    # any live assignment for the role, everywhere ; bound, only against
    # an assignment granted for that exact scope.
    describe "scope — a bound assignment's own scope" do
      def grant_scoped(runtime, actor_id:, role_name:, scope:)
        runtime.dispatch("Governance::RoleAssignment.Assign",
                         actor_id: { value: actor_id }, role_name: { value: role_name },
                         scope: { value: scope }, starts_at: { value: "2026-01-01" })
      end

      it "dispatches unchanged when scope is not bound, regardless of the assignment's own scope" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant_scoped(runtime, actor_id: "u7", role_name: "Chef", scope: "north-kitchen")
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        Hecks.as_caller(role: "Chef", actor_id: "u7") { order.prepare! }
        expect(order.events.map(&:name)).to include("OrderPrepared")
      end

      it "refuses an identified caller whose grant is for a different scope, once scope is bound" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant_scoped(runtime, actor_id: "u8", role_name: "Chef", scope: "north-kitchen")
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        expect {
          Hecks.as_caller(role: "Chef", actor_id: "u8", scope: "south-kitchen") { order.prepare! }
        }.to raise_error(Hecks::Runtime::Unauthorized)
      end

      it "dispatches when the bound scope matches the assignment's own scope" do
        runtime = build(&CAFETERIA_DOMAIN)
        grant_scoped(runtime, actor_id: "u9", role_name: "Chef", scope: "north-kitchen")
        Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
        order = Order.find("o1")

        Hecks.as_caller(role: "Chef", actor_id: "u9", scope: "north-kitchen") { order.prepare! }
        expect(order.events.map(&:name)).to include("OrderPrepared")
      end
    end
  end
end
