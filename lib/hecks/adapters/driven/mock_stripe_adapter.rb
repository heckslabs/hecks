# frozen_string_literal: true

module Hecks
  module Adapters
    # A generic stand-in for a real Checkout-Session-style adapter — no
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
      # Accepts and discards the shared adapter constructor arguments; this adapter holds no
      # state of its own.
      #
      # @param aggregate [Bluebook::Aggregate, nil] accepted for the shared adapter
      #   constructor shape and ignored
      # @param settings [Hash] accepted for the shared adapter constructor shape and ignored
      # @param root [String, nil] accepted for the shared adapter constructor shape and ignored
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Builds a fake checkout URL carrying `registration_id`, standing in for a real
      # Checkout-Session call.
      #
      # @param event [Object] the record data a real adapter would read the price and name
      #   from; adapter-defined shape (whatever the declaring bluebook's `checkout` port
      #   operation supplies as `event`) and never read here
      # @param registration_id [String] the registration id to key a signed webhook off of;
      #   embedded in the returned URL, never read otherwise
      # @param success_url [String] the base URL to redirect a successful payer to
      # @param cancel_url [String] accepted for the shared checkout-adapter call shape and
      #   never read
      # @return [String] `success_url` with `mock_checkout=1` and `mock_registration_id`
      #   query parameters appended
      def create_session(event:, registration_id:, success_url:, cancel_url:)
        separator = success_url.include?("?") ? "&" : "?"
        "#{success_url}#{separator}mock_checkout=1&mock_registration_id=#{registration_id}"
      end
    end
  end
end
