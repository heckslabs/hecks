# frozen_string_literal: true

module Hecksagain
  module Adapters
    # A GENERIC STAND-IN for a real Checkout-Session-style adapter — no
    # network call, no real account, matching whatever real payment
    # adapter a project pairs it with by shape alone
    # (`create_session(event:, registration_id:, success_url:, cancel_url:)
    # -> a URL string`), the same way `Memory` stands in for a real
    # persistence adapter without knowing anything about the domain bound
    # to it. Never reads `event`'s own fields — a real adapter needs the
    # price/name inside it to build a session a payer actually sees;
    # this only needs to look enough like one to swap in.
    #
    # The URL it returns carries the same `registration_id` a real
    # webhook's metadata would, so a caller building its own signed
    # webhook against it (a smoke test, CI) has something real to key
    # off of — the real shape production has, minus the network hop.
    class MockStripeAdapter
      def initialize(aggregate: nil, settings: {}, root: nil); end

      def create_session(event:, registration_id:, success_url:, cancel_url:)
        separator = success_url.include?("?") ? "&" : "?"
        "#{success_url}#{separator}mock_checkout=1&mock_registration_id=#{registration_id}"
      end
    end
  end
end
