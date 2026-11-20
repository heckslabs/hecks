# frozen_string_literal: true

require "json"
require_relative "integration_runs"
require_relative "../pipeline_integration"

module Hecks
  module Adapters
    module PipelineBoard
      # The runs of the MainIntegration saga as {PipelineStages} answers them: the `IntegrationRuns`
      # query and the tile the page is pushed. A read that fails is given as `{unknown: reason}`,
      # as every other section. Mixed into {Gather}, which supplies `guard`.
      module IntegrationTile
        # @return [Hash] the strip's Integration row with its `reading`, the runs the tile lists
        def integration_tile
          reading = guard { @integration.reading }
          IntegrationRuns.row(reading, @now.call).merge(reading: reading)
        end

        # @return [Hash{Symbol => String}] `text:` the runs of the MainIntegration saga, as JSON
        private

        # The readers of the stores: those of the work and, over the same store and the journal
        # they hold, the reader of the runs, unless one is given.
        def wire_stores(readers, registry)
          wire_work(readers, registry)
          @integration = readers.fetch(:integration) do
            PipelineIntegration.new(store: @seats, journal: @journal, now: @now)
          end
        end
      end
    end
  end
end
