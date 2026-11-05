# frozen_string_literal: true

require "json"
require "time"
require_relative "probe"
require_relative "pipeline_github"
require_relative "pipeline_git"
require_relative "pipeline_tickets"
require_relative "pipeline_jobs"
require_relative "pipeline_journal"
require_relative "../../hecks/adapters/push_size"
require_relative "pipeline_stages/agent_roles"
require_relative "pipeline_fill"
require_relative "pipeline_stages/gather"
require_relative "pipeline_stages/strip"
require_relative "pipeline_stages/metrics"
require_relative "pipeline_stages/fanout"

module Hecks
  module Adapters
    # The `Pipeline` port's adapter for `Stages`, and the one the page reads from: it asks each
    # reader (GitHub, Git, Tickets, Jobs, Journal, and the Dispatch.Fill dry run) its question,
    # turns the answers into the pipeline strip, the metric tiles and the fan-out, and gives
    # every section that failed as `{unknown: reason}`. It only reads.
    class PipelineStages
      include PipelineBoard::Gather

      # @param registry [Runtime::Registry, nil] the booted registry the Tickets reader uses
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `readers:` replaces any of `github`, `git`, `tickets`, `jobs`,
      #   `journal` and `fill`; `now:` is a callable answering the time
      # @param root [String, nil] the checkout the readers run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @now = settings[:now] || -> { Time.now.utc }
        wire(settings.fetch(:readers, {}), registry)
      end

      # @return [Hash{Symbol => String}] `text:` one row per stage as JSON
      def stages = { text: JSON.generate(PipelineBoard::Strip.build(sections, @now.call)) }

      # @return [Hash] every section the page shows: `stages`, `metrics`, the four tables, the
      #   fan-out and the events, each an answer or `{unknown: reason}`
      def state
        data = sections
        now = @now.call
        { generated_at: now.iso8601, roles: PipelineBoard::AgentRoles.of(data[:sessions], @roles),
          stages: PipelineBoard::Strip.build(data, now),
          metrics: PipelineBoard::Metrics.tiles(data.merge(push_limits: @push_limits, ci_health: @ci_health), now),
          ci_runs: data[:ci_runs], slowest_jobs: data[:slowest_jobs],
          open_work: data[:open_work], sessions: data[:sessions], events: data[:events], fanout: fanout(data) }
      end

      # @return [Array<Hash>, Hash] the newest events with the policies that reacted, or
      #   `{unknown: reason}`
      def feed = guard { @journal.recent(40) }

      private

      def wire(readers, registry)
        @push_limits = Hecks::Adapters::PushSize.thresholds(registry)
        @ci_health = PipelineBoard::CiTiles.health(registry)
        @roles = PipelineBoard::AgentRoles.declared(registry)
        @github = readers.fetch(:github) { PipelineGitHub.new(root: @root) }
        @git = readers.fetch(:git) { PipelineGit.new(root: @root) }
        @journal = readers.fetch(:journal) { PipelineJournal.new(root: @root) }
        @fill = readers.fetch(:fill) { PipelineFill.new(root: @root) }
        wire_work(readers, registry)
      end

      def wire_work(readers, registry)
        @tickets = readers.fetch(:tickets) { PipelineTickets.new(registry: registry) }
        @jobs = readers.fetch(:jobs) { PipelineJobs.new(settings: { runs: -> { guard { @tickets.runs } } }) }
      end

      def sections
        data = gathered
        data.merge(dated(data))
      end

      def fanout(data)
        return data[:sessions] unless data[:sessions].is_a?(Array)

        landed = data[:landed].is_a?(Array) ? data[:landed] : []
        work = data[:open_work].is_a?(Array) ? data[:open_work] : []
        mapped = PipelineBoard::Fanout.mapping(sessions: data[:sessions], work: work, landed: landed, fill: data[:fill])
        { rows: mapped, flags: PipelineBoard::Fanout.flags_of(mapped), fill: data[:fill], sessions: data[:sessions] }
      end
    end
  end
end
