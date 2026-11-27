# frozen_string_literal: true

require "hecks/harness/supervisor"

module Hecks
  module Adapters
    # The `Mail` port's adapter for the Harness: it hands a posted message to the running
    # supervisor ({Harness::Supervisor.current}), which writes it to the addressee at once or when
    # its turn ends. With no supervisor running, every ask is refused.
    class HarnessMail
      # What the supervisor writes of the ask; `about` is nil when the message answers nothing.
      FIELDS = %i[key sender addressee text about].freeze

      def initialize(**); end

      # @param ask [Hash] the `Deliver` ask's fields
      # @return [Hash] `handed`: "delivered" when it was written at once, "queued" when it is held
      # @raise [Harness::Supervisor::Refused] when the supervisor refuses, or none runs
      def deliver(**ask)
        told = supervisor.deliver(**FIELDS.to_h { |field| [field, plain(ask[field])] })
        { handed: told["tell"] }
      end

      # The runtime hands an ask the record it addresses, so a routed or handed-on message is
      # written from the ledger: its sender, its new addressee, its text and what it is about.
      #
      # @param ask [Hash] the `DeliverRecorded` ask's key, and the message as the ledger holds it
      # @return [Hash] as {#deliver}
      # @raise [Harness::Supervisor::Refused] as {#deliver}
      def deliver_recorded(**ask) = deliver(**ask)

      private

      def supervisor = Harness::Supervisor.current || raise(Harness::Supervisor::Refused, "no supervisor is running")

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
