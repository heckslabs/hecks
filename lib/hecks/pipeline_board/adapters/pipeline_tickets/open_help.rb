# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The calls for help that are not closed: what the Hecks `HelpWanted.Open` query answers,
      # asked of the live store when the board is told where it is, else of the booted registry.
      # Mixed into {PipelineTickets}, which supplies the store it asks. It only reads.
      module OpenHelp
        FIELDS = %i[help opened_at needs role status].freeze

        # @return [Array<Hash>] each open call's `help` key, `opened_at`, `needs`, `role` and
        #   `status`, the oldest block first
        def open_help
          found = @help || store.asked("Hecks", "HelpWanted", "Open")
          found.map { |record| FIELDS.to_h { |name| [name, field(record, name).to_s] } }
        end
      end
    end
  end
end
