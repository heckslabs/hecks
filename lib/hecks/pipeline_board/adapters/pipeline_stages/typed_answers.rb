# frozen_string_literal: true

require_relative "../probe"
require_relative "snapshot_rows"
require_relative "typed_rows"
require_relative "daily_health"
require_relative "glance_rows"
require_relative "glance_tap"
require_relative "../pipeline_status"
require_relative "board_reads"
require_relative "read_facts"

module Hecks
  module Adapters
    module PipelineBoard
      # The `Pipeline` port's typed answers: the one `Snapshot` row, its `Stage` and `Reading`
      # rows on their own, the cycles, the day's health and the integration runs. Each is what
      # the board read, reshaped as the bluebook's value objects; a read that failed refuses the
      # query with its reason. Mixed into {PipelineStages}, whose `state` holds the `Snapshot`
      # row under `board`.
      module TypedAnswers
        # @return [Hash] the bluebook's one `Snapshot` row: the whole read model, typed
        def board = state[:board]

        # @return [Hash] the bluebook's one `Glance` row: what needs a person or stands too long,
        #   and whether work is flowing
        def glance
          GlanceTap.record(@registry, @now.call)
          state[:glance]
        end

        # @param since [Hash, String, nil] a time the throughput also counts from
        # @return [Hash] the bluebook's one `Status` row: why nothing starts, throughput, each
        #   started Work item and each blocked run
        def now(since: nil)
          state
          PipelineStatus.build(@status_facts, @now.call, held(since))
        end

        # @return [Hash] the one `Reading` for Signalbox's signal, in plain words
        def signal = board[:signal]

        # @return [Array<Hash>] one `FillWhy` row for each item the fill did not start
        def fill_why = board[:fill_why]

        # @return [Array<Hash>] one `RedEpisodeLine` per episode, newest first
        def red_episodes(limit: nil) = board[:red_episodes].first(held(limit) || board[:red_episodes].size)

        # @return [Array<Hash>] one `Reading` per outcome measure
        def measures = board[:measures]

        # @return [Array<Hash>] one `Reading` per ranked epic
        def epics = board[:epics]

        # @return [Array<Hash>] one `Reading` per hold on boarding
        def holds = board[:holds]

        # @return [Array<Hash>] one `Stage` row per node of the strip, left to right
        def stages = board[:stages]

        # @return [Array<Hash>] one `Reading` row per number that is not on the strip
        def readings = board[:readings]

        # @param limit [Hash, Integer, nil] how many Work items (the `cycle_items` setting when nil)
        # @return [Array<Hash>] one `Cycle` row per recent Work item, newest first
        # @raise [Unavailable] when the stage events could not be read
        def cycles(limit: nil) = TypedRows.cycles(cycles_read(held(limit))[:cycles])

        # @return [Array<Hash>] one `Reading` per stage of a cycle: its median seconds
        # @raise [Unavailable] when the stage events could not be read
        def cycle_stats = TypedRows.cycle_stats(cycles_read, @now.call.iso8601)

        # The pipeline's own day, read from the event log, the sessions and the open findings only.
        #
        # @return [Array<Hash>] one `Reading` per `HealthCheck` row: how many it found, each named
        def daily_health
          data = { health_events: guard { @journal.health_events }, sessions: plain_rows { @jobs.rows },
                   open_findings: guard { @tickets.open_findings } }
          TypedRows.health(DailyHealth.build(data, @now.call), @now.call.iso8601)
        end

        # @return [Array<Hash>] one `IntegrationRun` row per run the saga remembers
        # @raise [Unavailable] when the saga's checkpoints could not be read
        def integration_runs = TypedRows.integration(read!(guard { @integration.reading })[:runs])

        private

        # The state with its typed `Snapshot` row under `board`.
        def with_board(held, data)
          @status_facts = data.merge(held.slice(:load_guard))
          held.merge(board:  SnapshotRows.build(held, data.slice(:train_prs, :release, :turns).merge(reads: reads(data))),
                     glance: GlanceRows.build(data.merge(held.slice(:load_guard)), @now.call))
        end

        # The newer readings, asked of the aggregates that own them.
        def reads(data)
          facts = ReadFacts.new(registry: @registry, tickets: @tickets, now: @now).of(data[:fill])
          BoardReads.build(facts, @now.call.iso8601)
        end

        # The cycles laid from the stage events as they stand now.
        def cycles_read(limit = nil) = read!(cycle_reading(guard { @journal.cycle_events }, limit))

        # The section as it was read.
        #
        # @raise [Unavailable] with the reason, when it holds `unknown:`
        def read!(section)
          raise Unavailable, section[:unknown].to_s if section.is_a?(Hash) && section.key?(:unknown)

          section
        end
      end
    end
  end
end
