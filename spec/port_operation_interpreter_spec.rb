require "spec_helper"

# THE PRIMARY/DRIVING PORT, END TO END — an adapter outside the bluebook
# calls PortOperationInterpreter (through Dispatcher#dispatch_port), never
# the domain itself. What this proves: the payload gate and coercion run the
# same as a command's, the emitted event carries the operation's own
# attributes verbatim (Emission's own contract, just without a mutated
# instance to source `id:` from), and a policy reacting to that event
# triggers a real command exactly as it would for a command-emitted one.
RSpec.describe "a port operation, dispatched" do
  def boot
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/payments.bluebook"))
      Hecks.hecksagon("Payments") do
        ::Payments::Payment.persisted_by("Memory")

        # THE PRIMARY PORT — called by an adapter outside the bluebook
        # entirely (a Stripe webhook, in the design this came out of). No
        # given, no then_set: this is the boundary translating an external
        # fact into our own vocabulary, not a place business rules live.
        # Those stay on ConfirmReceipt/RejectPayment, reached only through
        # a policy. Declared here, in the hecksagon, not the bluebook — the
        # boundary between the domain and its adapters IS what a hecksagon
        # already is for every other port.
        ::Payments::Payment.port "PaymentGateway" do
          operation "Receive" do
            reference_to Payment, as: :payment_id
            attribute :amount, Money
            emits "PaymentReceived"
          end

          operation "Decline" do
            reference_to Payment, as: :payment_id
            attribute :reason, DeclineReason
            emits "PaymentDeclined"
          end
        end
      end
    end

    registry.verify!
    [Hecksagain::Runtime::Dispatcher.new(registry), registry]
  end

  def open_payment(dispatcher, id: "P1", cents: 4200)
    dispatcher.dispatch("Payments::Payment.Open", payment_id: { value: id }, amount: { cents: cents })
  end

  it "gates unknown arguments the same way a command does" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect {
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                                payment_id: "P1", amount: { cents: 4200 }, surprise: true)
    }.to raise_error(Hecksagain::Runtime::UnknownArgument)
  end

  it "gates absent arguments the same way a command does" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect {
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive", payment_id: "P1")
    }.to raise_error(Hecksagain::Runtime::AbsentArgument)
  end

  it "refuses a reference to a payment that does not exist" do
    dispatcher, = boot

    expect {
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                                payment_id: "nonexistent", amount: { cents: 4200 })
    }.to raise_error(Hecksagain::Runtime::NotFound)
  end

  it "emits an event carrying the operation's own attributes, addressed by the reference" do
    dispatcher, = boot
    open_payment(dispatcher)

    events = dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                                       payment_id: "P1", amount: { cents: 4200 })

    expect(events.length).to eq(1)
    event = events.first
    expect(event.name).to eq("PaymentReceived")
    expect(event.aggregate).to eq("Payments::Payment")
    expect(event.id).to eq("P1")
    expect(event.payload[:payment_id]).to eq("P1")
    expect(event.payload[:amount].to_h).to eq(cents: 4200)
  end

  it "a policy reacting to the emitted event triggers the real command, mutating the aggregate" do
    dispatcher, registry = boot
    open_payment(dispatcher)

    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                              payment_id: "P1", amount: { cents: 4200 })

    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("received")
    expect(registry.reaction_log.last[:delivered]).to be(true)
  end

  it "the decline leg works the same way, through its own operation" do
    dispatcher, registry = boot
    open_payment(dispatcher)

    events = dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Decline",
                                       payment_id: "P1", reason: { code: "insufficient_funds", message: "card declined" })

    expect(events.first.name).to eq("PaymentDeclined")

    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("declined")
    expect(payment[:decline_reason].to_h).to eq(code: "insufficient_funds", message: "card declined")
  end

  it "refuses a second Receive once the payment is no longer pending — the guard on ConfirmReceipt, not the port" do
    dispatcher, registry = boot
    open_payment(dispatcher)
    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Receive",
                              payment_id: "P1", amount: { cents: 4200 })

    dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Decline",
                              payment_id: "P1", reason: { code: "x", message: "y" })

    expect(registry.reaction_log.last[:delivered]).to be(false)
    payment = registry.repository("Payments", registry.bluebook("Payments").aggregate("Payment")).find("P1")
    expect(payment[:status]).to eq("received")
  end

  it "raises UnknownVerb for an operation the port does not declare" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect {
      dispatcher.dispatch_port("Payments", "Payment", "PaymentGateway", "Nonsense", payment_id: "P1")
    }.to raise_error(Hecksagain::Runtime::UnknownVerb)
  end

  it "raises UnknownVerb for a port the aggregate does not declare" do
    dispatcher, = boot
    open_payment(dispatcher)

    expect {
      dispatcher.dispatch_port("Payments", "Payment", "Nonsense", "Receive", payment_id: "P1")
    }.to raise_error(Hecksagain::Runtime::UnknownVerb)
  end

  # THE SAME OPERATION, BY VERB — the wire spelling `Dispatcher#dispatch`
  # itself now resolves ("Domain::Aggregate.Port.Operation", the same
  # shape an entity command already uses, ports checked first). Not a
  # second implementation: `dispatch` delegates to the identical
  # `@port_ops` primitive `dispatch_port` calls, so everything above
  # already proves the behavior — this proves the DOOR, the one a
  # differential-parity script (`spec/corpus/*.json`'s flat `{"verb",
  # "args"}` steps, `bin/rust_conformance`'s own oracle) can actually
  # reach, since neither carries a domain/aggregate/port/operation
  # 4-tuple, only ever a verb string.
  describe "reached through Dispatcher#dispatch, by verb, rather than #dispatch_port" do
    it "emits the operation's event and triggers the policy exactly as dispatch_port does" do
      dispatcher, registry = boot
      open_payment(dispatcher)

      result = dispatcher.dispatch("Payments::Payment.PaymentGateway.Receive",
                                    payment_id: "P1", amount: { cents: 4200 })

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

      expect {
        dispatcher.dispatch("Payments::Payment.PaymentGateway.Nonsense", payment_id: "P1")
      }.to raise_error(Hecksagain::Runtime::UnknownVerb, /PaymentGateway has no operation "Nonsense"/)
    end

    it "falls through to entity-command handling for a dotted verb naming no port" do
      dispatcher, = boot
      open_payment(dispatcher)

      expect {
        dispatcher.dispatch("Payments::Payment.NoSuchThing.Whatever", payment_id: "P1")
      }.to raise_error(Hecksagain::Runtime::UnknownVerb, /Payment has no entity "NoSuchThing"/)
    end
  end
end
