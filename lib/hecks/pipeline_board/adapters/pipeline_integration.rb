# frozen_string_literal: true

require_relative "probe"
require_relative "pipeline_stages/integration_runs"

module Hecks
  module Adapters
    # Reads the runs of the MainIntegration saga for the board: the stage stored for each run,
    # from the checkpoints the saga keeps, and the time of each run's last event, from the event
    # log. It reads only: it dispatches nothing and no step of a run is reachable from it.
    class PipelineIntegration
      # The bluebook that declares the saga.
      DOMAIN = "Hecks"

      # @param store [PipelineBoard::RegistryStore] answers the saga's checkpoints
      # @param journal [#integration_seen] answers what the event log's tail says of the runs
      # @param now [#call] answers the time
      def initialize(store:, journal:, now: -> { Time.now.utc })
        @store = store
        @journal = journal
        @now = now
      end

      # @return [Hash] the runs as {PipelineBoard::IntegrationRuns.build} lays them
      # @raise [PipelineBoard::Unavailable] when the checkpoints cannot be read
      def reading
        stored = @store.sagas(DOMAIN, MainIntegration::Runs::SAGA)
        PipelineBoard::IntegrationRuns.build(stored, seen, @now.call)
      end

      private

      # The log is for the ages only, so a log that cannot be read leaves the stages standing.
      def seen
        @journal.integration_seen
      rescue StandardError
        {}
      end
    end
  end
end
