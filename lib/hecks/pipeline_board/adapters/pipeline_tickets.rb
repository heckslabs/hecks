# frozen_string_literal: true

require "json"
require_relative "probe"
require_relative "live_store"
require_relative "rows"
require_relative "pipeline_tickets/run_detail"
require_relative "pipeline_tickets/stopped_runs"
require_relative "pipeline_tickets/standing_facts"
require_relative "pipeline_tickets/finished_times"
require_relative "pipeline_tickets/closed_work"
require_relative "pipeline_tickets/project_work"
require_relative "pipeline_tickets/open_help"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `Tickets` port's adapter: answers `OpenWork` with the Work items that are not done, and
    # reports which session ran each work item from the AgentRun records. What counts as undone, as
    # a running or tidyable run and as a status count is asked of the queries and the read model
    # the Tickets and Hecks bluebooks declare (`Work.Undone`, `WorkByStatus`, `AgentRun.Running`,
    # `AgentRun.Tidyable`), from the live store or the board's own registry. It only reads.
    class PipelineTickets
      include PipelineBoard::RunDetail
      include PipelineBoard::StoppedRuns
      include PipelineBoard::StandingFacts
      include PipelineBoard::FinishedTimes
      include PipelineBoard::ProjectWork
      include PipelineBoard::OpenHelp

      # The statuses a stand-in list of Work items is not open in; a store is asked `Work.Undone`.
      DONE = %w[done dropped].freeze
      # The queries of `AgentRun` whose runs the live store answers.
      LISTED = %w[Running Tidyable].freeze
      WORK_ITEM_LINE = /^(?:WORK ITEM|ROW):\s*(\S+)/
      # How long the runs read stays good: the jobs reader asks for them once per session.
      RUNS_TTL = 20
      EMPTY = "the Tickets store holds no Work items here (Memory); run the board from the main checkout"

      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `work_items:`, `landings:` and `findings:` stand in for the
      #   registry's Work, Landing and Finding records, and `help:` for its open calls for help;
      #   `projects_dir:` is where the projects'
      #   checkouts sit, for `ProjectWork` (the parent of the board's own checkout when absent)
      # @param root [String, nil] unused
      # `live_store:` in `settings` stands in for the {PipelineBoard::LiveStore} read when the board
      # is told where the live store is (`PIPELINE_BOARD_LAUNCHER_ROOT`).
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @live = settings.fetch(:live_store) { live_store_named }
        @registry = registry
        @own = PipelineBoard::RegistryStore.new(registry: registry)
        @standin, @epics_standin = settings.values_at(:work_items, :epics)
        @landed, @stopped = settings.values_at(:landings, :findings)
        @finished, @work_times = settings.values_at(:finished_times, :work_times)
        @projects_dir, @help = settings.values_at(:projects_dir, :help)
      end

      # @return [Array<Hash>] the open Work items as `WorkLine` rows: slug, status, area, who
      #   claimed each and when, and where it stands in the plan
      def open_work = PipelineBoard::Rows.of("WorkLine", undone)

      # @return [Array<Hash>] the open Work items as the page and the plan read them
      # @raise [PipelineBoard::Unavailable] when the store holds no Work items here
      def undone_work = undone

      # @return [Array<Hash>] each Epic with its title, outcome, tier and how many members are done
      #   or dropped; none when the Tickets domain holds no epic
      def epics
        return @epics_standin if @epics_standin

        works = work_records
        epic_records.map { |record| epic_row(record, works) }
      end

      # @return [Hash{String => Integer}] every Work item counted by status
      # @raise [PipelineBoard::Unavailable] when the store holds no Work item at all
      def counts
        found = @standin ? @standin.map { |item| item[:status] }.tally : store.tallied("Tickets", "WorkByStatus")
        raise PipelineBoard::Unavailable, EMPTY if found.empty?

        found
      end

      # @return [Hash{String => Hash}] each AgentRun's session id with its `work_item` (named on the
      #   first line of its brief) and `status`; the session a run held before an answer's resume
      #   started a copy (`forked_from`) is listed too, `superseded_by` the session it follows now
      def runs
        return @runs_held[:value] if @runs_held && Time.now - @runs_held[:at] < RUNS_TTL

        @runs_held = { at: Time.now, value: run_records.flat_map { |run| sessions_of(run) }.to_h }
        @runs_held[:value]
      end

      # The AgentRun records of the live store when the board is told where it is, else the booted
      # registry's. From the live store only the runs `AgentRun.Running` and `AgentRun.Tidyable`
      # answer are kept, so a run that was retired or refused long ago does not reach the
      # plan-review panel, which reads a transcript for each.
      def run_records
        return records_of("Hecks", "AgentRun") unless @live

        LISTED.flat_map { |query| @live.asked("Hecks", "AgentRun", query) }
      end

      # @return [Array<String>] the branches the Landing records say were merged onto main, with any
      #   leading `qa/` taken off
      def landed_branches
        landings = @landed || landing_records
        landed = landings.select { |land| field(land, :status).to_s == "landed" }
        landed.map { |land| field(land, :branch).to_s.delete_prefix("qa/") }
      end

      private

      # The store that is asked: the live one when the board is told where it is, else its own.
      def store = @live || @own

      # The Work items `Work.Undone` answers, in plan order. A store with no Work item at all is
      # said to be empty (see {#counts}); one whose items are all done answers none.
      def undone
        counts
        return @standin.reject { |item| DONE.include?(item[:status]) } if @standin

        store.asked("Tickets", "Work", "Undone").map { |row| item(row) }
      end

      # The live store held by the checkout named in `PIPELINE_BOARD_LAUNCHER_ROOT`, if any.
      def live_store_named
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
        PipelineBoard::LiveStore.new(root: root) unless root.empty?
      end

      # The Landing records: the live store's, else the booted registry's.
      def landing_records = @live ? @live.records("Delivery", "Landing") : records_of("Delivery", "Landing")

      def item(record)
        { slug: field(record, :work).to_s, status: field(record, :status).to_s, title: field(record, :title).to_s,
          area: StartedWork.words(field(record, :area)), claimed_by: field(record, :claimed_by).to_s,
          claimed_at: field(record, :claimed_at).to_s }.merge(plan_fields(record))
      end

      # What the planning page shows of an item beyond its claim.
      def plan_fields(record)
        { priority: field(record, :priority).to_s, category: field(record, :category).to_s,
          epic: field(record, :epic).to_s, budget_minutes: field(record, :budget_minutes),
          yield_count: field(record, :yield_count).to_i, reason: field(record, :reason).to_s,
          step: field(record, :step).to_s, decision: field(record, :decision).to_s }
      end

      def work_records = @live ? @live.records("Tickets", "Work") : records_of("Tickets", "Work")

      def epic_records = @live ? @live.records("Tickets", "Epic") : records_of("Tickets", "Epic")

      def epic_row(record, works)
        key = field(record, :epic).to_s
        mine = works.select { |work| field(work, :epic).to_s == key }
        { epic: key, title: field(record, :title).to_s, outcome: field(record, :outcome).to_s,
          tier: field(record, :tier).to_s, decision: field(record, :decision).to_s }
          .merge(hand_hold(record), closed(mine))
      end

      def closed(works) = PipelineBoard::ClosedWork.of(works, method(:field))

      # @return [Hash] when the owner's hand ranked the epic (epoch seconds, 0 when never) and
      #   for how many seconds that rank holds
      def hand_hold(record) = { hand_ranked_at: field(record, :hand_ranked_at).to_i, hold: field(record, :hold).to_i }

      # The run under its current session and, when it forked, under the session it held before.
      # The current session is listed last, so it wins should the two ids be one.
      def sessions_of(run)
        current = field(run, :session).to_s
        forked = field(run, :forked_from).to_s
        held = forked.empty? ? [] : [[forked, run_item(run).merge(superseded_by: current)]]
        held + [[current, run_item(run)]]
      end

      def run_item(run)
        { work_item: work_item_of(run), status: field(run, :status).to_s,
          run: field(run, :run).to_s, repo: field(run, :repo).to_s, agent: field(run, :agent).to_s,
          works_as: field(run, :works_as).to_s, condition: field(run, :condition).to_s,
          started_at: field(run, :started_at).to_s, parent: field(run, :parent).to_s }
      end

      # The Work item a run names, else the one the first line of its brief names.
      def work_item_of(run)
        named = field(run, :work).to_s
        named.empty? ? field(run, :brief).to_s[WORK_ITEM_LINE, 1].to_s : named
      end

      # The booted registry's records, through the store that keeps each aggregate for a few
      # seconds, so the readers of one refresh (the open work, its counts, the epics, the plan
      # tile) share a single load of it.
      def records_of(domain, name) = @own.records(domain, name)

      def field(record, name) = StartedWork.value(record, name)
    end
  end
end
