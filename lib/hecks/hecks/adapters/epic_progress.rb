# frozen_string_literal: true

require_relative "epic_members"

module Hecks
  module Adapters
    # The `EpicProgress` port's adapter for `Tickets::Work`: one epic's members counted by what
    # became of them, and the next planned member in plan order. It reads and never writes.
    class EpicProgress
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param held [Hash] the query's `epic`
      # @return [Hash{Symbol => String}] `text:` the counts and the next planned item
      def epic_progress(**held)
        key = held[:epic].is_a?(Hash) ? held[:epic][:value] : held[:epic]
        members = EpicMemberRows.of(@registry, key)
        { text: "#{counts(members)}\nnext: #{upcoming(members)}\n" }
      end

      private

      def counts(members)
        done, dropped = %w[done dropped].map { |status| members.count { |member| member[:status] == status } }
        "done #{done}, dropped #{dropped}, open #{members.size - done - dropped}"
      end

      def upcoming(members)
        planned = members.select { |member| member[:status] == "planned" }
        planned.min_by { |member| [member[:step].to_i, member[:key]] }&.fetch(:key) || "none"
      end
    end
  end
end
