# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The open findings that stopped integration runs and shipments filed (the Tickets
      # `Finding.Stopped` query: source `pipeline`, reported or triaged), read from the live store
      # when the board is told where it is, else from the booted registry. Mixed into
      # {PipelineTickets}, which supplies the readers it uses.
      module StoppedRuns
        OPEN = %w[reported triaged].freeze
        FIELDS = %i[finding stage commit body].freeze

        # @return [Array<Hash>] each open stopped-run finding's `finding` (the run), `stage`,
        #   `commit` and `body` (the reason), oldest key first
        def stopped_runs
          found = (@stopped || finding_records).select { |record| stopped?(record) }
          found.map { |record| FIELDS.to_h { |name| [name, field(record, name).to_s] } }
               .sort_by { |run| run[:finding] }
        end

        private

        def finding_records = @live ? @live.records("Tickets", "Finding") : records_of("Tickets", "Finding")

        def stopped?(record)
          field(record, :source).to_s == "pipeline" && OPEN.include?(field(record, :status).to_s)
        end
      end
    end
  end
end
