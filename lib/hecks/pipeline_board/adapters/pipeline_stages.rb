# frozen_string_literal: true

require "json"
require "time"
require_relative "probe"
require_relative "live_store"
require_relative "rules"
require_relative "pipeline_github"
require_relative "pipeline_git"
require_relative "pipeline_tickets"
require_relative "pipeline_jobs"
require_relative "pipeline_journal"
require_relative "pipeline_disk"
require_relative "pipeline_boots"
require_relative "pipeline_stages/disk_tiles"
require_relative "../../hecks/adapters/push_size"
require_relative "pipeline_stages/agent_roles"
require_relative "pipeline_fill"
require_relative "pipeline_stages/gather"
require_relative "pipeline_stages/strip"
require_relative "pipeline_stages/metrics"
require_relative "pipeline_stages/fanout"
require_relative "pipeline_stages/train_detail"
require_relative "pipeline_stages/commit_link"
require_relative "pipeline_stages/panel"
require_relative "pipeline_stages/daily_health"
require_relative "pipeline_stages/owner_queue"
require_relative "pipeline_stages/headline"
require_relative "pipeline_stages/plan_reading"
require_relative "pipeline_stages/plan_tile"

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
        health = PipelineBoard::DailyHealth.build(data, now)
        { generated_at: now.iso8601, stages: PipelineBoard::Strip.build(data, now), daily_health: health,
          metrics: metrics(data, now, health), fanout: fanout(data),
          live_store_problem: @live&.problem }.merge(tables(data), panels(data))
      end

      # The sections the page shows as they were read: CI on main and on train pull requests, the
      # Work items, the sessions and the events.
      def tables(data)
        data.slice(:ci_runs, :slowest_jobs, :train_ci_runs, :train_slowest_jobs, :train_flakes, :open_work, :sessions, :events)
      end

      # @param limit [Hash, Integer, nil] how many Work items (the `cycle_items` setting when nil)
      # @return [Hash{Symbol => String}] `text:` the cycles, newest first, and each stage's median
      #   and percentile, as JSON
      def cycles(limit: nil)
        { text: JSON.generate(cycle_reading(guard { @journal.cycle_events }, held(limit))) }
      end

      # The pipeline's own day, read from the event log, the sessions and the open findings only.
      #
      # @return [Hash{Symbol => String}] `text:` each check's findings and the line, as JSON
      def daily_health
        data = { health_events: guard { @journal.health_events }, sessions: queried { @jobs.sessions },
                 open_findings: guard { @tickets.open_findings } }
        { text: JSON.generate(PipelineBoard::DailyHealth.build(data, @now.call)) }
      end

      # The state the page shows, drawn as a text panel for a terminal. It reads what `/api/state`
      # reads, and the open train pull requests besides; it writes nothing.
      #
      # @param width [Hash, Integer, nil] the panel's columns
      # @param colour [Hash, String, nil] `true` to colour rows by their state
      # @param limit [Hash, Integer, nil] how many planned Work items and finished sessions to list
      # @return [Hash{Symbol => String}] `text:` the panel
      def snapshot(width: nil, colour: nil, limit: nil)
        drawn = state.merge(train_prs: guard { @github.train_prs })
        { text: PipelineBoard::Panel.render(drawn, width: held(width), colour: held(colour).to_s == "true", limit: held(limit)) }
      end

      # @return [Hash] the next fill's dry run (see {PipelineFill#preview}), or `{unknown: reason}`
      def fill_tile = guard { @fill.preview }

      # The Train stage read again now, past the kept git answers: the tile is drawn because the
      # journal said the train moved.
      #
      # @return [Hash] the Train row of the strip
      def train_tile = PipelineBoard::Strip.train(guard { @git.train_now }, @now.call)

      # @return [Array<Hash>, Hash] the newest events with the policies that reacted, or
      #   `{unknown: reason}`
      def feed = guard { @journal.recent(40) }

      # @param key [String] an AgentRun's key or session id
      # @return [Hash, nil] the run's record, with `commits`: each landed sha and its links
      def run_detail(key)
        run = @tickets.run_detail(key)
        run&.merge(commits: commits_of(run[:landed]))
      end

      # @param key [String] a SendTrain run key
      # @return [Hash, nil] the boarding's outcome and its pull request, nil when none has the key
      def train_detail(key) = @trains.of(key)

      # The shas as commit links on the repository and, where the CI rows know the sha, the CI run.
      def commits_of(shas)
        base = guard { @github.repo_url }
        runs = guard { JSON.parse(@github.ci_runs[:text], symbolize_names: true) }
        shas.map { |sha| PipelineBoard::CommitLink.of(sha, base, runs) }
      end

      private

      # The metric tiles, the daily health line's last.
      def metrics(data, now, health)
        PipelineBoard::Metrics.tiles(data.merge(@limits), now) + [PipelineBoard::DailyHealth.tile(health)]
      end

      # The panels beside the strip: the pinned agents and the Work items' cycles.
      def panels(data) = agents(data).merge(cycles: cycle_reading(data[:cycle_events]))

      # The cycles laid from the stage events, or the events' `{unknown: reason}` as it was read.
      def cycle_reading(events, limit = nil)
        return events unless events.is_a?(Array)

        PipelineBoard::Cycles.build(events, @now.call, limit)
      end

      # An argument as the query hands it: the value inside a value object, or the value itself.
      def held(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      # The thresholds the tiles judge against, read from the Hecks world once.
      def read_limits(registry)
        { push_limits: Hecks::Adapters::PushSize.thresholds(registry), ci_health: PipelineBoard::CiTiles.health(registry),
          disk_health: PipelineBoard::DiskTiles.health(registry) }
      end

      def wire(readers, registry)
        PipelineBoard::Rules.use(registry)
        @limits = read_limits(registry)
        @roles = PipelineBoard::AgentRoles.declared(registry)
        wire_machine(readers, registry)
        @github = readers.fetch(:github) { PipelineGitHub.new(root: @root) }
        @git = readers.fetch(:git) { PipelineGit.new(root: @root) }
        @journal = readers.fetch(:journal) { PipelineJournal.new(root: @root) }
        @fill = readers.fetch(:fill) { PipelineFill.new(root: @root, registry: registry) }
        wire_work(readers, registry)
      end

      # The readers of the machine itself: the room on its disk and what its launcher boots cost.
      def wire_machine(readers, registry)
        @disk = readers.fetch(:disk) { PipelineDisk.new(root: @root) }
        @boots = readers.fetch(:boots) { PipelineBoots.new(registry: registry) }
      end

      def wire_work(readers, registry)
        live = @live = live_store_named
        @tickets = readers.fetch(:tickets) { PipelineTickets.new(registry: registry, settings: { live_store: live }) }
        @jobs = readers.fetch(:jobs) { PipelineJobs.new(settings: { runs: -> { guard { @tickets.runs } } }) }
        @trains = readers.fetch(:trains) do
          PipelineBoard::TrainDetail.new(root:       ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root),
                                         live_store: live || PipelineBoard::RegistryStore.new(registry: registry))
        end
      end

      # The one in-process reader of the checkout `PIPELINE_BOARD_LAUNCHER_ROOT` names, shared by
      # the readers that need its store, and already opening; nil when the board is not pointed at
      # another checkout, which then reads its own registry and boots no second copy of the domain.
      def live_store_named
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
        PipelineBoard::LiveStore.new(root: root).warm unless root.empty?
      end

      # The pinned agents panel: each role with its live sessions and last event, and the open
      # plan reviews and promotion recommendations.
      def agents(data)
        { roles: PipelineBoard::AgentRoles.of(data[:sessions], @roles, data[:events]),
          reviews: PipelineBoard::AgentRoles.reviews(guard { @tickets.runs }), recommendations: PipelineBoard::AgentRoles.recommendations(data[:promotions]) }
      end

      def sections
        data = owned(gathered)
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
