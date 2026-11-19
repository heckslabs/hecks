# frozen_string_literal: true

module Hecks
  module Adapters
    # Asks Signalbox's Response table how one session kind answers a band (ADR 0222 law 3): it
    # boots Signalbox alone in Memory, once, asks `Response.Ask` and answers the status the table's
    # policies left. It decides nothing itself; booting Signalbox runs no beat and posts nothing,
    # since only a `Beat.Begin` starts the chain that looks and posts.
    class LocalResponse
      # The directory Signalbox boots from.
      DIRECTORY = File.expand_path("..", __dir__)

      # The command that asks the table.
      VERB = "Signalbox::Response.Ask"

      # @param registry [Runtime::Registry, nil] a registry that holds Signalbox; booted when absent
      def initialize(registry: nil)
        @registry = registry
        @asked = 0
      end

      # @param role [String] coder, helper, gate, orchestrator, repair or person
      # @param tier [String] urgent, normal or low
      # @param band [String] the band the signal is in
      # @return [String] running, deferring, leaving or waiting; asked when no policy answered
      def answer(role:, tier:, band:)
        key = "#{Process.pid}-#{@asked += 1}"
        dispatcher.dispatch_flat(VERB, response: { value: key }, session: { value: key }, role: { value: role },
                                       tier: { value: tier }, band: { value: band })
        status_of(key)
      end

      private

      def registry
        @registry ||= Hecks.boot(DIRECTORY, install_driving: false, environment: nil).registry
      end

      def dispatcher = (@dispatcher ||= Runtime::Dispatcher.new(registry))

      def status_of(key)
        aggregate = registry.bluebook("Signalbox").aggregates.find { |held| held.hecks_name == "Response" }
        status = registry.repository("Signalbox", aggregate).find(key)&.then { |record| field(record, :status) }
        status.to_s
      end

      def field(record, name)
        held = record.respond_to?(:[]) ? record[name] : record.public_send(name)
        held.is_a?(Hash) ? held[:value] : held
      end
    end
  end
end
