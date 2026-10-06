require "spec_helper"
require "time"

# Role checks at dispatch: opt-in on both sides (no caller bound, or no declared role,
# dispatches as if there were no role), refused once a caller states a role that does not match.
RSpec.describe "role-based command rejections" do
  def load_ports
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(File.expand_path("../../lib/hecks/ports/authorization.port", __dir__))
    Kernel.load(File.expand_path("../../lib/hecks/adapters/driven/governance_authorization.adapter", __dir__))
  end

  def bind_cafeteria_hecksagons
    Hecks.hecksagon("Cafeteria") do
      attaches "Governance"
      Cafeteria::Order.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def build(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_ports
      Hecks.bluebook("Cafeteria", &block)
      bind_cafeteria_hecksagons
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

  def event_names(order) = order.events.map(&:name)

  def current_role = Hecks::Runtime::Caller.current.role

  # The roles seen inside the inner block, then the outer block, then once both have exited.
  def nested_caller_roles
    inner = outer = nil
    Hecks.as_caller(role: "Customer") do
      Hecks.as_caller(role: "Chef") { inner = current_role }
      outer = current_role
    end
    [inner, outer, Hecks::Runtime::Caller.current]
  end

  it "dispatches unchanged when no caller is bound" do
    build(&CAFETERIA_DOMAIN)
    order = Order.place!(ref: { value: "o1" })
    expect(event_names(order)).to include("OrderPlaced")
  end

  it "dispatches when the bound caller's role matches the command's" do
    build(&CAFETERIA_DOMAIN)
    Hecks.as_caller(role: "Customer") do
      order = Order.place!(ref: { value: "o1" })
      expect(event_names(order)).to include("OrderPlaced")
    end
  end

  it "refuses when the bound caller's role does not match" do
    build(&CAFETERIA_DOMAIN)
    expect do
      Hecks.as_caller(role: "Chef") { Order.place!(ref: { value: "o1" }) }
    end.to raise_error(Hecks::Runtime::Unauthorized, /refused — role: Customer, and the caller stated Chef/)
  end

  it "dispatches unchanged when the command declares no role at all" do
    build(&CAFETERIA_DOMAIN)
    order = Order.place!(ref: { value: "o1" })
    Hecks.as_caller(role: "Anyone At All") { order.cancel! }
    expect(order.events.last.name).to eq("OrderCancelled")
  end

  it "restores the outer binding once a nested as_caller block exits" do
    build(&CAFETERIA_DOMAIN)

    expect(nested_caller_roles).to eq(["Chef", "Customer", nil])
  end

  it "does not carry the triggering caller's role into a policy's reaction command", :aggregate_failures do
    runtime = build(&CAFETERIA_DOMAIN)
    Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }

    reaction = runtime.reactions.first
    expect(reaction[:delivered]).to be(true)
    expect(event_names(Order.find("o1"))).to include("OrderPrepared")
  end

  # With Governance attached, a caller who also names `actor_id` is checked against a real
  # `RoleAssignment`; `role:` and `actor_id:` disagreeing proves identity wins over the string.
  describe "an identified caller, checked against a real Governance grant" do
    def grant(runtime, actor_id:, role_name:, scope: "kitchen")
      runtime.dispatch_flat("Governance::RoleAssignment.Assign",
                            actor_id: { value: actor_id }, role_name: { value: role_name },
                            scope: { value: scope }, starts_at: { value: "2026-01-01" })
    end

    def placed_order
      Hecks.as_caller(role: "Customer") { Order.place!(ref: { value: "o1" }) }
      Order.find("o1")
    end

    def prepare_as(order, **caller) = Hecks.as_caller(role: "Chef", **caller) { order.prepare! }

    it "dispatches when the actor holds the command's role via a real assignment" do
      grant(build(&CAFETERIA_DOMAIN), actor_id: "u1", role_name: "Chef")
      order = placed_order

      prepare_as(order, actor_id: "u1")
      expect(event_names(order)).to include("OrderPrepared")
    end

    it "refuses an identified caller with no matching grant, even though the role it typed matches" do
      build(&CAFETERIA_DOMAIN)
      order = placed_order

      expect { prepare_as(order, actor_id: "u2") }
        .to raise_error(Hecks::Runtime::Unauthorized, /refused — role: Chef, and the caller stated Chef/)
    end

    it "refuses an identified caller whose real assignment is for a different role" do
      grant(build(&CAFETERIA_DOMAIN), actor_id: "u3", role_name: "Customer")
      order = placed_order

      expect { prepare_as(order, actor_id: "u3") }.to raise_error(Hecks::Runtime::Unauthorized)
    end

    # `as_of` is opt-in on top of `actor_id`: unbound, a future `starts_at` authorizes at once.
    describe "as_of — a bound assignment's own starts_at" do
      before { grant(build(&CAFETERIA_DOMAIN), actor_id: "u4", role_name: "Chef") } # starts_at: "2026-01-01"

      it "dispatches unchanged when as_of is not bound, even for a not-yet-started assignment" do
        order = placed_order

        prepare_as(order, actor_id: "u4")
        expect(event_names(order)).to include("OrderPrepared")
      end

      it "refuses an identified caller whose real assignment has not started yet, once as_of is bound" do
        order = placed_order
        before_start = Time.parse("2025-12-31").to_i

        expect { prepare_as(order, actor_id: "u4", as_of: before_start) }.to raise_error(Hecks::Runtime::Unauthorized)
      end

      it "dispatches when as_of is bound and the assignment has already started" do
        order = placed_order
        after_start = Time.parse("2026-06-01").to_i

        prepare_as(order, actor_id: "u4", as_of: after_start)
        expect(event_names(order)).to include("OrderPrepared")
      end
    end

    # `scope` is opt-in too: unbound matches any live role assignment; bound, only that scope.
    describe "scope — a bound assignment's own scope" do
      before { grant(build(&CAFETERIA_DOMAIN), actor_id: "u7", role_name: "Chef", scope: "north-kitchen") }

      it "dispatches unchanged when scope is not bound, regardless of the assignment's own scope" do
        order = placed_order

        prepare_as(order, actor_id: "u7")
        expect(event_names(order)).to include("OrderPrepared")
      end

      it "refuses an identified caller whose grant is for a different scope, once scope is bound" do
        order = placed_order

        expect { prepare_as(order, actor_id: "u7", scope: "south-kitchen") }.to raise_error(Hecks::Runtime::Unauthorized)
      end

      it "dispatches when the bound scope matches the assignment's own scope" do
        order = placed_order

        prepare_as(order, actor_id: "u7", scope: "north-kitchen")
        expect(event_names(order)).to include("OrderPrepared")
      end
    end
  end
end
