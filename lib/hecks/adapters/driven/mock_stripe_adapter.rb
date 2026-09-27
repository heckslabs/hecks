# frozen_string_literal: true

module Hecks
  module Adapters
    # A network-free stand-in for a Checkout-Session-style payment adapter, matching it by
    # method shape alone. The returned URL carries `registration_id`, as webhook metadata would.
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
      # @param event [Object] the record data a real adapter would read; never read here
      # @param registration_id [String] embedded in the returned URL, never read otherwise
      # @param success_url [String] the base URL to redirect a successful payer to
      # @param cancel_url [String] accepted for the shared call shape and never read
      # @return [String] `success_url` with `mock_checkout=1` and `mock_registration_id`
      #   query parameters appended
      def create_session(event:, registration_id:, success_url:, cancel_url:)
        separator = success_url.include?("?") ? "&" : "?"
        "#{success_url}#{separator}mock_checkout=1&mock_registration_id=#{registration_id}"
      end
    end
  end
end
