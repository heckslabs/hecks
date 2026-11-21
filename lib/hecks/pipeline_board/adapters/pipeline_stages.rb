# frozen_string_literal: true

require "json"
require "time"
require_relative "probe"
require_relative "live_store"
require_relative "load_history"
require_relative "restart_notes"
require_relative "load_causes"
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
require_relative "pipeline_stages/pruning_standing"
require_relative "pipeline_fill"
require_relative "pipeline_stages/gather"
require_relative "pipeline_stages/strip"
require_relative "pipeline_stages/metrics"
require_relative "pipeline_stages/fanout"
require_relative "pipeline_stages/fill_age"
require_relative "pipeline_stages/train_detail"
require_relative "pipeline_stages/commit_link"
require_relative "pipeline_stages/panel"
require_relative "pipeline_stages/daily_health"
require_relative "pipeline_stages/owner_queue"
require_relative "pipeline_stages/headline"
require_relative "pipeline_stages/plan_reading"
require_relative "pipeline_stages/plan_tile"
require_relative "pipeline_stages/throughput_days"
require_relative "pipeline_stages/typed_answers"

module Hecks
  module Adapters
    # The `Pipeline` port's adapter for `Stages`, and the one the page reads from: it asks each
    # reader (GitHub, Git, Tickets, Jobs, Journal, and the Dispatch.Fill dry run) its question,
    # turns the answers into the pipeline strip, the metric tiles and the fan-out, and gives
    # every section that failed as `{unknown: reason}`. It only reads.
    class PipelineStages
      include PipelineBoard::Gather
      include PipelineBoard::TypedAnswers

      # @param registry [Runtime::Registry, nil] the booted registry the Tickets reader uses
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `readers:` replaces any of `github`, `git`, `tickets`, `jobs`,
      #   `journal` and `fill`; `now:` is a callable answering the time
      # @param root [String, nil] the checkout the readers run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @registry = registry
        @now = settings[:now] || -> { Time.now.utc }
        wire(settings.fetch(:readers, {}), registry)
      end

      # @return [Hash] every section the page shows: `stages`, `metrics`, the four tables, the
      #   fan-out and the events, each an answer or `{unknown: reason}`, and under `board` the
      #   same state as the typed `Snapshot` row
      def state
        data = sections
        with_board(drawn(data, @now.call), data)
      end

      # The sections the page shows as they were read: CI on main and on train pull requests, the
      # Work items, the sessions and the events.
      def tables(data)
        data.slice(:ci_runs, :slowest_jobs, :train_ci_runs, :train_slowest_jobs, :train_flakes, :open_work, :sessions, :events)
      end

      # The state the page shows, drawn as a text panel for a terminal. It reads what `/api/state`
      # reads, and the open train pull requests besides; it writes nothing.
      #
      # @param width [Hash, Integer, nil] the panel's columns
      # @param colour [Hash, String, nil] `true` to colour rows by their state
      # @param limit [Hash, Integer, nil] how many planned Work items and finished sessions to list
      # @return [Hash{Symbol => String}] `text:` the panel
      def snapshot(width: nil, colour: nil, limit: nil)
        drawn = state.merge(train_prs: train_prs)
        { text: PipelineBoard::Panel.render(drawn, width: held(width), colour: held(colour).to_s == "true", limit: held(limit)) }
      end

      # @return [Array<Hash>, Hash] the open train pull requests the panel lists, or
      #   `{unknown: reason}`
      def train_prs = guard { @github.train_prs }

      # @return [Hash] the next fill's dry run (see {PipelineFill#preview}), or `{unknown: reason}`
      def fill_tile = guard { @fill.preview }

      # The Train stage, from the git answers the reader keeps for its few seconds: a run of
      # journal lines draws the tile from one read and starts no `git` per line.
      #
      # @return [Hash] the Train row of the strip
      def train_tile = PipelineBoard::Strip.train(guard { @git.train }, @now.call)

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
        runs = guard { @github.ci_runs }
        shas.map { |sha| PipelineBoard::CommitLink.of(sha, base, runs) }
      end

      private

      # The sections as the hand-written page reads them.
      def drawn(data, now)
        health = PipelineBoard::DailyHealth.build(data, now)
        { generated_at: now.iso8601, stages: PipelineBoard::Strip.build(data, now), daily_health: health,
          metrics: metrics(data, now, health), fanout: fanout(data), live_store_problem: @live&.problem,
          stale_sections: noted_sections(data), load_guard: PipelineBoard::LoadGuard.standing }.merge(tables(data), panels(data))
      end

      # The sections showing an earlier answer, the fill among them while its report is stale.
      def noted_sections(data) = PipelineBoard::FillAge.noted(stale_sections, data[:fill])

      # The metric tiles, the daily health line's last.
      def metrics(data, now, health)
        PipelineBoard::Metrics.tiles(data.merge(@limits), now) + [PipelineBoard::DailyHealth.tile(health)]
      end

      # The panels beside the strip: the pinned agents, the Work items' cycles and the runs.
      def panels(data)
        agents(data).merge(cycles:          cycle_reading(data[:cycle_events]), **data.slice(:integration, :waiting_on_you),
                           throughput_days: PipelineBoard::ThroughputDays.build(data[:finished_times], @now.call),
                           **PipelineBoard::LoadCauses.with_history, **PipelineBoard::RestartNotes.with_state)
      end

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
        @github = readers.fetch(:github) { PipelineGitHub.new(root: @root, settings: { seats: -> { @seats } }) }
        @git = readers.fetch(:git) { PipelineGit.new(root: @root) }
        @journal = readers.fetch(:journal) { PipelineJournal.new(root: @root) }
        wire_stores(readers, registry)
        @fill = readers.fetch(:fill) { PipelineFill.new(root: @root, registry: registry, store: @live) }
      end

      # The readers of the machine itself: the room on its disk and what its launcher boots cost.
      def wire_machine(readers, registry)
        @disk = readers.fetch(:disk) { PipelineDisk.new(root: @root) }
        @boots = readers.fetch(:boots) { PipelineBoots.new(registry: registry) }
      end

      def wire_work(readers, registry)
        live = @live = PipelineBoard::LiveStore.named
        @tickets = readers.fetch(:tickets) { PipelineTickets.new(registry: registry, settings: { live_store: live }) }
        @seats = readers.fetch(:seats) { live || PipelineBoard::RegistryStore.new(registry: registry) }
        @jobs = readers.fetch(:jobs) { PipelineJobs.new(settings: { runs: -> { guard { @tickets.runs } } }) }
        @trains = readers.fetch(:trains) do
          PipelineBoard::TrainDetail.new(root: ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root), live_store: @seats)
        end
      end

      # The pinned agents panel: each role with its live sessions and last event, whether pruning
      # is paused, and the open plan reviews.
      def agents(data)
        { roles: PipelineBoard::AgentRoles.of(data[:sessions], @roles, data[:events]), pruning: PipelineBoard::PruningStanding.of(@seats),
          reviews: PipelineBoard::AgentRoles.review_lines(guard { @tickets.runs }) }
      end

      def sections = owned(gathered).then { |data| data.merge(dated(data)) }

      def fanout(data)
        return data[:sessions] unless data[:sessions].is_a?(Array)

        landed = data[:landed].is_a?(Array) ? data[:landed] : []
        work = data[:open_work].is_a?(Array) ? data[:open_work] : []
        mapped = PipelineBoard::Fanout.mapping(sessions: data[:sessions], work: work, landed: landed, fill: data[:fill])
        { rows: mapped, flags: PipelineBoard::Fanout.flags_of(mapped), fill: PipelineBoard::FillAge.marked(data[:fill]), sessions: data[:sessions] }
      end
    end
  end
end
