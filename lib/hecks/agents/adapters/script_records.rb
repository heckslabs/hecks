# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"
require "hecks/agents/adapters/routing_guard/script_gate"

module Hecks
  module Adapters
    # The `ScriptRecords` port's adapter for `Script`: answers `Candidates` by counting the scripts
    # every session's record says it ran. It reads the `Script` records and writes nothing; a
    # script run twice, in one session or across several, is a command the bluebooks lack.
    class ScriptRecords
      # @param registry [Runtime::Registry, nil] whose Agents store holds the `Script` records
      # @param records [#call, nil] stand-in: answers the records, each a hash with `ran:`
      def initialize(registry: nil, records: nil)
        @registry = registry
        @records = records || method(:kept_records)
      end

      # @return [Hash{Symbol => String}] `text:` one line per script run twice or more, the count
      #   then the command, most run first; empty when none was
      def candidates(**)
        lines = repeated.sort_by { |command, count| [-count, command] }.map { |command, count| "#{count}  #{command}" }
        { text: lines.join("\n") }
      end

      private

      # @return [Hash{String => Integer}] each script run twice or more, with its count
      def repeated
        every = @records.call.flat_map { |record| ran(record) }
        every.tally.select { |_, count| count >= 2 }
      end

      def ran(record)
        Array(StartedWork.value(record, :ran)).map { |entry| entry.respond_to?(:value) ? entry.value : plain(entry) }
      end

      def plain(entry) = entry.is_a?(Hash) ? entry[:value].to_s : entry.to_s

      def kept_records
        aggregate = RoutingGuard::ScriptGate.aggregate(@registry)
        aggregate ? @registry.repository("Agents", aggregate).all : []
      end
    end
  end
end
