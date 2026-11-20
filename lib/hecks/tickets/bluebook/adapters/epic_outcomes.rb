# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/epic_members"
require "hecks/tickets/bluebook/adapters/outcome_readings/subject"

module Hecks
  module Adapters
    # The `EpicOutcomes` port's adapter for `Tickets::Epic`: every epic, lowest tier first (an epic
    # nobody ranked last), with the measure it names, the state its last reading left and its
    # members counted. The state is the stored one, so it reads no tap; an epic that names no
    # measure is answered `unstated`. It reads and never writes.
    class EpicOutcomes
      # The tier an epic nobody ranked sorts as: past the last tier.
      UNRANKED = 10

      # @param registry [Runtime::Registry, nil] the booted registry whose epics and work are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @return [Hash{Symbol => String}] `text:` a JSON array, one entry per epic in ranked order
      def outcomes(**)
        ranked = epics.each_with_index.sort_by { |epic, at| [field(epic, :tier) || UNRANKED, at] }.map(&:first)
        { text: "#{JSON.pretty_generate(ranked.map { |epic| entry(epic) })}\n" }
      end

      private

      def entry(epic)
        key = field(epic, :epic).to_s
        measure = field(epic, :measure).to_s.strip
        { epic: key, title: field(epic, :title), tier: field(epic, :tier), status: field(epic, :status).to_s,
          measure: measure.empty? ? nil : measure, measured: measured(epic, measure),
          evidence: field(epic, :evidence), members: counts(EpicMemberRows.of(@registry, key)) }
      end

      def measured(epic, measure)
        return "unstated" if measure.empty?

        stored = field(epic, :measured).to_s
        stored.empty? ? "unread" : stored
      end

      def counts(members)
        done, dropped = %w[done dropped].map { |status| members.count { |member| member[:status] == status } }
        { done: done, dropped: dropped, open: members.size - done - dropped, all: members.size }
      end

      def field(record, name) = StartedWork.value(record, name)

      def epics
        aggregate = OutcomeReadings::Subject.epic_aggregate(@registry)
        aggregate ? @registry.repository("Tickets", aggregate).all : []
      end
    end
  end
end
