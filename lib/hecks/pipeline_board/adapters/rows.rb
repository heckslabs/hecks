# frozen_string_literal: true

require_relative "rules"

module Hecks
  module Adapters
    module PipelineBoard
      # A reader's own rows cut to the fields a value object of the bluebook declares, so a query
      # answers that value object and nothing the reader keeps for itself. A field the reader
      # could not read is left out, and the runtime fills the default the bluebook declares.
      module Rows
        module_function

        # @param name [String] a value object of the PipelineBoard bluebook, such as `"CiRun"`
        # @param rows [Array<Hash>] a reader's rows
        # @return [Array<Hash>] each row with only the declared fields it holds
        def of(name, rows) = rows.map { |row| one(name, row) }

        # @param name [String] a value object of the PipelineBoard bluebook
        # @param row [Hash] one of a reader's rows
        # @return [Hash] the row with only the declared fields it holds
        def one(name, row) = row.slice(*Rules.fields(name)).compact
      end
    end
  end
end
