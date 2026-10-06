require "spec_helper"

# A driving port end to end: an adapter calls PortOperationInterpreter through
# Dispatcher#dispatch_port, gated like a command, and a policy reacts to the emitted event.
RSpec.describe "a port operation, dispatched" do
  # No given, no sets: the port only translates an external fact (a Stripe webhook).
  # Business rules stay on ConfirmReceipt/RejectPayment, reached through a policy.
  PAYMENT_GATEWAY_OPERATIONS = proc do
    operation "Receive" do
      attribute :amount, Money
      emits "PaymentReceived"
    end

    operation "Decline" do
      attribute :reason, DeclineReason
      emits "PaymentDeclined"
    end
  end

  RECEIVE_ARGS = { to: "P1", with: { amount: { cents: 4200 } } }.freeze
  DECLINE_ARGS = { to: "P1", with: { reason: { code: "insufficient_funds", message: "card declined" } } }.freeze

  def load_payments_files
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
  end

  def declare_hecksagons
    Hecks.hecksagon("Payments") do
      attaches "Governance"
      Payments::Payment.persisted_by("Memory")
      Payments::Payment.port "PaymentGateway", &PAYMENT_GATEWAY_OPERATIONS
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_payments_files
      declare_hecksagons
    end

    registry.verify!
    [Hecks::Runtime::Dispatcher.new(registry), registry]
  end

  def open_payment(dispatcher, id: "P1", cents: 4200)
    dispatcher.dispatch_flat("Payments::Payment.Open", payment_id: { value: id }, amount: { cents: cents })
  end

  def dispatch_port(port, operation, **args) = @dispatcher.dispatch_port("Payments", "Payment", port, operation, **args)

  def dispatch_gateway(operation, **args) = dispatch_port("PaymentGateway", operation, **args)

  def payment = @registry.repository("Payments", @registry.bluebook("Payments").aggregate("Payment")).find("P1")

  before do
    @dispatcher, @registry = boot
    open_payment(@dispatcher)
  end

  it "gates unknown arguments the same way a command does" do
    expect { dispatch_gateway("Receive", to: "P1", with: { amount: { cents: 4200 }, surprise: true }) }
      .to raise_error(Hecks::Runtime::UnknownArgument)
  end

  it "gates absent arguments the same way a command does" do
    expect { dispatch_gateway("Receive", to: "P1", with: {}) }.to raise_error(Hecks::Runtime::AbsentArgument)
  end

  it "refuses a reference to a payment that does not exist" do
    expect { dispatch_gateway("Receive", to: "nonexistent", with: { amount: { cents: 4200 } }) }
      .to raise_error(Hecks::Runtime::NotFound)
  end

  context "when a Receive is dispatched" do
    let(:events) { dispatch_gateway("Receive", **RECEIVE_ARGS) }

    it "emits one event carrying the operation's name, addressed by the reference" do
      event = events.first

      expect([events.length, event.name, event.aggregate, event.id]).to eq([1, "PaymentReceived", "Payments::Payment", "P1"])
    end

    it "carries the operation's own attributes, not the reference", :aggregate_failures do
      payload = events.first.payload

      expect(payload).not_to have_key(:payment_id)
      expect(payload[:amount].to_h).to eq(cents: 4200)
    end
  end

  it "a policy reacting to the emitted event triggers the real command, mutating the aggregate", :aggregate_failures do
    dispatch_gateway("Receive", **RECEIVE_ARGS)

    expect(payment[:status]).to eq("received")
    expect(@registry.reaction_log.last[:delivered]).to be(true)
  end

  it "the decline leg emits its own event, through its own operation" do
    expect(dispatch_gateway("Decline", **DECLINE_ARGS).first.name).to eq("PaymentDeclined")
  end

  it "the decline leg records the decline on the aggregate", :aggregate_failures do
    dispatch_gateway("Decline", **DECLINE_ARGS)

    expect(payment[:status]).to eq("declined")
    expect(payment[:decline_reason].to_h).to eq(code: "insufficient_funds", message: "card declined")
  end

  it "refuses a second Receive once the payment is no longer pending " \
     "— the guard on ConfirmReceipt, not the port", :aggregate_failures do
    dispatch_gateway("Receive", **RECEIVE_ARGS)
    dispatch_gateway("Decline", to: "P1", with: { reason: { code: "x", message: "y" } })

    expect(@registry.reaction_log.last[:delivered]).to be(false)
    expect(payment[:status]).to eq("received")
  end

  it "raises UnknownVerb for an operation the port does not declare" do
    expect { dispatch_gateway("Nonsense", flat: { payment_id: "P1" }) }.to raise_error(Hecks::Runtime::UnknownVerb)
  end

  it "raises UnknownVerb for a port the aggregate does not declare" do
    expect { dispatch_port("Nonsense", "Receive", flat: { payment_id: "P1" }) }.to raise_error(Hecks::Runtime::UnknownVerb)
  end

  # Same operation by verb ("Domain::Aggregate.Port.Operation"): `dispatch` delegates to the
  # primitive `dispatch_port` uses, and parity scripts can only reach it through a verb string.
  describe "reached through Dispatcher#dispatch, by verb, rather than #dispatch_port" do
    it "emits the operation's event exactly as dispatch_port does", :aggregate_failures do
      result = @dispatcher.dispatch("Payments::Payment.PaymentGateway.Receive", **RECEIVE_ARGS)

      expect([result.instance, result.id]).to eq([nil, nil])
      expect(result.events.map(&:name)).to eq(["PaymentReceived"])
    end

    it "triggers the policy exactly as dispatch_port does", :aggregate_failures do
      @dispatcher.dispatch("Payments::Payment.PaymentGateway.Receive", **RECEIVE_ARGS)

      expect(payment[:status]).to eq("received")
      expect(@registry.reaction_log.last[:delivered]).to be(true)
    end

    it "raises UnknownVerb naming the operation for one the port does not declare" do
      expect { @dispatcher.dispatch_flat("Payments::Payment.PaymentGateway.Nonsense", payment_id: "P1") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /PaymentGateway has no operation "Nonsense"/)
    end

    it "falls through to entity-command handling for a dotted verb naming no port" do
      expect { @dispatcher.dispatch_flat("Payments::Payment.NoSuchThing.Whatever", payment_id: "P1") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /Payment has no entity "NoSuchThing"/)
    end
  end
end
