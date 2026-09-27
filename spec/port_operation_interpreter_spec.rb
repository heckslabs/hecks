require "spec_helper"

# A driving port end to end: an adapter calls PortOperationInterpreter through
# Dispatcher#dispatch_port, gated like a command, and a policy reacts to the emitted event.
RSpec.describe "a port operation, dispatched" do
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
      Hecks.hecksagon("Payments") do
        uses_framework "Governance"
        Payments::Payment.persisted_by("Memory")

        # No given, no sets: the port only translates an external fact (a Stripe webhook).
        # Business rules stay on ConfirmReceipt/RejectPayment, reached through a policy.
        Payments::Payment.port "PaymentGateway" do
          operation "Receive" do
            attribute :amount, Money
            emits "PaymentReceived"
          end

          operation "Decline" do
            attribute :reason, DeclineReason
            emits "PaymentDeclined"
          end
        end
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    [Hecks::Runtime::Dispatcher.new(registry), registry]
  end

  def open_payment(dispatcher, id: "P1", cents: 4200)
    dispatcher.dispatch_flat("Payments::Payment.Open", payment_id: { value: id }, amount: { cents: cents })
  end

  it "gates unknown arguments the same way a command does" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect do
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                               to: "P1", with: { amount: { cents: 4200 }, surprise: true })
    end.to raise_error(Hecks::Runtime::UnknownArgument)
  end

  it "gates absent arguments the same way a command does" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect do
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive", to: "P1", with: {})
    end.to raise_error(Hecks::Runtime::AbsentArgument)
  end

  it "refuses a reference to a payment that does not exist" do
    dispatcher, = boot

    expect do
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                               to: "nonexistent", with: { amount: { cents: 4200 } })
    end.to raise_error(Hecks::Runtime::NotFound)
  end

  it "emits an event carrying the operation's own attributes, addressed by the reference" do
    dispatcher, = boot
    open_payment(dispatcher)

    events = dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                                      to: "P1", with: { amount: { cents: 4200 } })

    expect(events.length).to eq(1)
    event = events.first
    expect(event.name).to eq("PaymentReceived")
    expect(event.aggregate).to eq("Payments::Payment")
    expect(event.id).to eq("P1")
    expect(event.payload).not_to have_key(:payment_id)
    expect(event.payload[:amount].to_h).to eq(cents: 4200)
  end

  it "a policy reacting to the emitted event triggers the real command, mutating the aggregate" do
    dispatcher, registry = boot
    open_payment(dispatcher)

    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                             to: "P1", with: { amount: { cents: 4200 } })

    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("received")
    expect(registry.reaction_log.last[:delivered]).to be(true)
  end

  it "the decline leg works the same way, through its own operation" do
    dispatcher, registry = boot
    open_payment(dispatcher)

    events = dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Decline",
                                      to: "P1", with: { reason: { code: "insufficient_funds", message: "card declined" } })

    expect(events.first.name).to eq("PaymentDeclined")

    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("declined")
    expect(payment[:decline_reason].to_h).to eq(code: "insufficient_funds", message: "card declined")
  end

  it "refuses a second Receive once the payment is no longer pending — the guard on ConfirmReceipt, not the port" do
    dispatcher, registry = boot
    open_payment(dispatcher)
    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                             to: "P1", with: { amount: { cents: 4200 } })

    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Decline",
                             to: "P1", with: { reason: { code: "x", message: "y" } })

    expect(registry.reaction_log.last[:delivered]).to be(false)
    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("received")
  end

  it "raises UnknownVerb for an operation the port does not declare" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect do
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Nonsense", flat: { payment_id: "P1" })
    end.to raise_error(Hecks::Runtime::UnknownVerb)
  end

  it "raises UnknownVerb for a port the aggregate does not declare" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect do
      dispatcher.dispatch_port("Payments", "Payment", "Nonsense", "Receive", flat: { payment_id: "P1" })
    end.to raise_error(Hecks::Runtime::UnknownVerb)
  end

  # Same operation by verb ("Domain::Aggregate.Port.Operation"): `dispatch` delegates to the
  # primitive `dispatch_port` uses, and parity scripts can only reach it through a verb string.
  describe "reached through Dispatcher#dispatch, by verb, rather than #dispatch_port" do
    it "emits the operation's event and triggers the policy exactly as dispatch_port does" do
      dispatcher, registry = boot
      open_payment(dispatcher)

      result = dispatcher.dispatch("Payments::Payment.PaymentGateway.Receive",
                                   to: "P1", with: { amount: { cents: 4200 } })

      expect(result.instance).to be_nil
      expect(result.id).to be_nil
      expect(result.events.map(&:name)).to eq(["PaymentReceived"])

      payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
      expect(payment[:status]).to eq("received")
      expect(registry.reaction_log.last[:delivered]).to be(true)
    end

    it "raises UnknownVerb naming the operation for one the port does not declare" do
      dispatcher, = boot
      open_payment(dispatcher)

      expect do
        dispatcher.dispatch_flat("Payments::Payment.PaymentGateway.Nonsense", payment_id: "P1")
      end.to raise_error(Hecks::Runtime::UnknownVerb, /PaymentGateway has no operation "Nonsense"/)
    end

    it "falls through to entity-command handling for a dotted verb naming no port" do
      dispatcher, = boot
      open_payment(dispatcher)

      expect do
        dispatcher.dispatch_flat("Payments::Payment.NoSuchThing.Whatever", payment_id: "P1")
      end.to raise_error(Hecks::Runtime::UnknownVerb, /Payment has no entity "NoSuchThing"/)
    end
  end
end
