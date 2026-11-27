# frozen_string_literal: true

require "hecks/harness/supervisor"

module Hecks
  module Adapters
    # The `Mail` port's adapter for the Harness: it hands a posted message to the running
    # supervisor ({Harness::Supervisor.current}), which writes it to the addressee at once or when
    # its turn ends. With no supervisor running, every ask is refused.
    class HarnessMail
      def initialize(**); end

      # @return [Hash] `handed`: "delivered" when it was written at once, "queued" when it is held
      # @raise [Harness::Supervisor::Refused] when the supervisor refuses, or none runs
      def deliver(key:, sender:, addressee:, text:, **)
        told = supervisor.deliver(key: plain(key), sender: plain(sender), addressee: plain(addressee), text: plain(text))
        { handed: told["tell"] }
      end

      private

      def supervisor = Harness::Supervisor.current || raise(Harness::Supervisor::Refused, "no supervisor is running")

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
