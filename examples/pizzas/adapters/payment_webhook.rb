require "json"
require "rack"
require_relative "payment_signature"

module PizzaShop
  # The driving adapter between a payment processor and Pizzas: a Rack app that verifies the
  # processor's signed "payment succeeded" delivery and restates it in the domain's words through
  # `Order.PaymentGateway.Receive`, the port `pizzas.hecksagon` declares.
  #
  # It does not decide whether the pizza sells. The port only emits `PizzaPaymentReceived`;
  # `OnPizzaPaymentReceived` reaches `Purchase`, whose `given` rules decide. A payment the domain
  # declines is still answered 200, saying why: the fact is true, and a non-2xx would only make
  # the processor retry it.
  class PaymentWebhook
    # The header the processor signs each delivery in.
    SIGNATURE_HEADER = "HTTP_STRIPE_SIGNATURE".freeze

    # The processor's event type for money that arrived; every other type is acknowledged.
    SUCCEEDED = "payment_intent.succeeded".freeze

    # `secret:` has no default: a missing secret would silently accept anyone's delivery.
    #
    # @param runtime [Hecks::Runtime::Dispatcher] the booted Pizzas runtime the port is told on
    # @param secret [String] the processor's webhook signing secret
    # @param clock [#call] answers the current `Time`, so a test can sign in the past
    # @raise [ArgumentError] if `secret` is nil or empty
    def initialize(runtime:, secret:, clock: -> { Time.now })
      raise ArgumentError, "no payment webhook secret configured" if secret.to_s.empty?

      @runtime = runtime
      @secret  = secret
      @clock   = clock
    end

    # Answers one delivery from the processor.
    #
    # @param env [Hash{String => Object}] the Rack environment
    # @return [Array(Integer, Hash{String => String}, Array<String>)] the Rack response: 405 for
    #   anything but POST, 401 for a bad signature, 400 for a body that is not JSON, 422 for a
    #   payment the domain cannot read, otherwise 200 with what happened as JSON
    def call(env)
      request = Rack::Request.new(env)
      return respond(405, error: "MethodNotAllowed", message: "POST only") unless request.post?

      body = request.body.read
      PaymentSignature.verify!(@secret, request.get_header(SIGNATURE_HEADER), body, now: @clock.call)
      route(JSON.parse(body))
    rescue PaymentSignature::Invalid => e
      respond(401, error: "InvalidSignature", message: e.message)
    rescue JSON::ParserError => e
      respond(400, error: "MalformedPayload", message: e.message)
    end

    private

    def route(event)
      return respond(200, ok: true, ignored: event["type"].to_s) unless event["type"] == SUCCEEDED

      receive(event.dig("data", "object") || {})
    end

    def receive(payment)
      pizza, customer = payment.fetch("metadata", {}).values_at("pizza", "customer_name")
      return unreadable("metadata.pizza and metadata.customer_name name the order") unless pizza && customer

      respond(200, ok: true, pizza: pizza, **tell(pizza, customer, payment["amount_received"]))
    rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
      unreadable(e.message)
    end

    # Reads this delivery's reactions off the log by position, which assumes deliveries are
    # handled one at a time, as the single-threaded development server does.
    def tell(pizza, customer, cents)
      before = @runtime.registry.reaction_log.size
      result = @runtime.dispatch("Pizzas::Order.PaymentGateway.Receive",
                                 to: pizza, with: { customer_name: { value: customer }, amount: { cents: cents } })
      declined = @runtime.registry.reaction_log[before..].find { |reaction| !reaction[:delivered] }
      { events: result.events.map(&:name), sold: declined.nil?, refused: declined&.dig(:reason) }.compact
    end

    def unreadable(message) = respond(422, error: "UnreadablePayment", message: message)

    def respond(status, body)
      [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
    end
  end
end
