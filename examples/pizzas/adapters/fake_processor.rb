require "json"
require "securerandom"
require_relative "payment_signature"

module PizzaShop
  # A stand-in for the payment processor, for tests and a local run: it writes the delivery a
  # Stripe-style processor would send when a payment succeeds, and signs it with the shared
  # secret. It talks to no network and holds no real credentials.
  #
  # Only the processor is fake. `PaymentWebhook`, which receives the delivery, is the adapter a
  # real deployment runs.
  class FakeProcessor
    # @param secret [String] the webhook signing secret this processor shares with the shop
    def initialize(secret:)
      @secret = secret
    end

    # Writes and signs the delivery for a payment that succeeded.
    #
    # @param pizza [String] the pizza's name, carried in `metadata` as the shop attached it
    # @param customer_name [String] who paid, also carried in `metadata`
    # @param cents [Integer] the amount the processor received, in cents
    # @param at [Time] the moment the delivery is signed
    # @return [Array(String, String)] the JSON body and its signature header value
    def payment_succeeded(pizza:, customer_name:, cents:, at: Time.now)
      body = JSON.generate(
        id:   "evt_#{SecureRandom.hex(8)}",
        type: PaymentWebhook::SUCCEEDED,
        data: { object: { amount_received: cents, metadata: { pizza: pizza, customer_name: customer_name } } }
      )
      [body, PaymentSignature.sign(@secret, body, at: at)]
    end
  end
end
