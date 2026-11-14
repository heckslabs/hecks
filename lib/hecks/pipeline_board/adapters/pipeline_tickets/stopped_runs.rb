# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The open findings that stopped integration runs and shipments filed, and every open finding
      # for the daily health line: what the Tickets `Finding.Stopped` and `Finding.Open` queries
      # answer, asked of the live store when the board is told where it is, else of the booted
      # registry. Mixed into {PipelineTickets}, which supplies the store it asks.
      module StoppedRuns
        # The statuses a stand-in list of findings is open in; a store is asked the queries.
        OPEN = %w[reported triaged].freeze
        FIELDS = %i[finding stage commit body].freeze

        # @return [Array<Hash>] each open stopped-run finding's `finding` (the run), `stage`,
        #   `commit` and `body` (the reason), oldest key first
        def stopped_runs
          found = @stopped ? @stopped.select { |record| stopped?(record) } : store.asked("Tickets", "Finding", "Stopped")
          found.map { |record| FIELDS.to_h { |name| [name, field(record, name).to_s] } }
               .sort_by { |run| run[:finding] }
        end

        # @return [Array<Hash>] every open finding's `finding` key and `source`, whatever filed it,
        #   oldest key first
        def open_findings
          found = @stopped ? @stopped.select { |record| open?(record) } : store.asked("Tickets", "Finding", "Open")
          found.map { |record| { finding: field(record, :finding).to_s, source: field(record, :source).to_s } }
               .sort_by { |finding| finding[:finding] }
        end

        private

        def open?(record) = OPEN.include?(field(record, :status).to_s)

        def stopped?(record) = field(record, :source).to_s == "pipeline" && open?(record)
      end
    end
  end
end
