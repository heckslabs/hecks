# frozen_string_literal: true

require_relative "event_pump/cursors"
require_relative "event_pump/reactions"
require_relative "event_pump/reader"
require_relative "event_pump/consumer"

module Hecks
  module Adapters
    # The pump behind EventDelivery's `Pump.Run` (ADR 0178): reads each attached domain's event log
    # past its cursor and runs the policies that react to what it reads. A consumer reads the logs
    # its hecksagon subscribes to; each cursor is one (log, consumer) `EventDelivery::Consumer` and
    # each answered policy one `EventDelivery::Reaction`, both kept by the ledger that attaches
    # EventDelivery. The pump writes no domain's event log.
    #
    # A policy that has a reaction recorded for its event is not run again. A refused reaction is
    # recorded and named, and the cursor moves past it. A cursor does not move for an event whose
    # reaction could not run at all: that consumer stops, and the pump reports it failed.
    class EventPump
      # @param attached [#names, #runtime, #dir, #known?, #reacted?] the domains the pump reads and
      #   reacts for, and the ledger (`attached.runtime(ledger)`) that holds the rows
      # @param ledger [String] the name of the attached domain whose runtime holds EventDelivery
      def initialize(attached:, ledger:)
        @attached = attached
        @ledger = ledger
      end

      # Runs every consumer once.
      #
      # @return [Hash] `lines:` one per reaction and per problem, `failed:` whether a consumer
      #   stopped
      def run
        consumers = @attached.names.map do |name|
          Consumer.new(name, attached: @attached, cursors: cursors, reactions: reactions)
        end
        lines = consumers.flat_map(&:lines)
        { lines: lines, failed: consumers.any?(&:failed?) }
      end

      private

      def runtime = @attached.runtime(@ledger)

      def cursors = @cursors ||= Cursors.new(runtime)

      def reactions = @reactions ||= Reactions.new(runtime)
    end
  end
end
