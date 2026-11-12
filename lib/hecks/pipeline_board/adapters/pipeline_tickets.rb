# frozen_string_literal: true

require "json"
require_relative "probe"
require_relative "live_store"
require_relative "pipeline_tickets/run_detail"
require_relative "pipeline_tickets/stopped_runs"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `Tickets` port's adapter: answers `OpenWork` with the Work items that are not done, read
    # through the booted Tickets domain's repository (never from its database), and reports which
    # session ran each work item from the AgentRun records. It only reads.
    class PipelineTickets
      include PipelineBoard::RunDetail
      include PipelineBoard::StoppedRuns

      DONE = %w[done dropped].freeze
      # The AgentRun statuses the `Running` and `Tidyable` queries select.
      LISTED = %w[started finished].freeze
      WORK_ITEM_LINE = /^(?:WORK ITEM|ROW):\s*(\S+)/
      # How long the runs read stays good: the jobs reader asks for them once per session.
      RUNS_TTL = 20
      EMPTY = "the Tickets store holds no Work items here (Memory); run the board from the main checkout"

      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `work_items:`, `landings:` and `findings:` stand in for the
      #   registry's Work, Landing and Finding records
      # @param root [String, nil] unused
      # `live_store:` in `settings` stands in for the {PipelineBoard::LiveStore} read when the board
      # is told where the live store is (`PIPELINE_BOARD_LAUNCHER_ROOT`).
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @live = settings.fetch(:live_store) { live_store_named }
        @standin = settings[:work_items]
        @epics_standin = settings[:epics]
        @landed = settings[:landings]
        @stopped = settings[:findings]
      end

      # @return [Hash{Symbol => String}] `text:` the open work items as JSON: slug, status, area,
      #   and
      #   who claimed each and when
      def open_work = { text: JSON.generate(items.reject { |item| DONE.include?(item[:status]) }) }

      # @return [Array<Hash>] each Epic with its title, outcome, tier and how many members are done
      #   or dropped; none when the Tickets domain holds no epic
      def epics
        return @epics_standin if @epics_standin

        works = work_records
        epic_records.map { |record| epic_row(record, works) }
      end

      # @return [Hash{String => Integer}] every Work item counted by status
      def counts = items.map { |item| item[:status] }.tally

      # @return [Hash{String => Hash}] each AgentRun's session id with its `work_item` (named on the
      #   first line of its brief) and `status`
      def runs
        return @runs_held[:value] if @runs_held && Time.now - @runs_held[:at] < RUNS_TTL

        @runs_held = { at: Time.now, value: run_records.to_h { |run| [field(run, :session).to_s, run_item(run)] } }
        @runs_held[:value]
      end

      # The AgentRun records of the live store when the board is told where it is, else the booted
      # registry's. From the live store only the runs `AgentRun.running` and `AgentRun.tidyable`
      # answer are kept (started and finished), so a run that was retired or refused long ago does
      # not reach the plan-review panel, which reads a transcript for each.
      def run_records
        return records_of("Hecks", "AgentRun") unless @live

        @live.records("Hecks", "AgentRun").select { |run| LISTED.include?(field(run, :status).to_s) }
      end

      # @return [Array<String>] the branches the Landing records say were merged onto main, with any
      #   leading `qa/` taken off
      def landed_branches
        landings = @landed || landing_records
        landed = landings.select { |land| field(land, :status).to_s == "landed" }
        landed.map { |land| field(land, :branch).to_s.delete_prefix("qa/") }
      end

      private

      def items
        found = @standin || from_live_store || records_of("Tickets", "Work").map { |record| item(record) }
        raise PipelineBoard::Unavailable, EMPTY if found.empty?

        found
      end

      # The undone Work items of the live store, when the board is told where it is. Nil otherwise.
      def from_live_store
        return nil unless @live

        @live.records("Tickets", "Work").map { |record| item(record) }.reject { |work| DONE.include?(work[:status]) }
      end

      # The live store held by the checkout named in `PIPELINE_BOARD_LAUNCHER_ROOT`, if any.
      def live_store_named
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
        PipelineBoard::LiveStore.new(root: root) unless root.empty?
      end

      # The Landing records: the live store's, else the booted registry's.
      def landing_records = @live ? @live.records("Hecks", "Landing") : records_of("Hecks", "Landing")

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
          step: field(record, :step).to_s }
      end

      def work_records = @live ? @live.records("Tickets", "Work") : records_of("Tickets", "Work")

      def epic_records = @live ? @live.records("Tickets", "Epic") : records_of("Tickets", "Epic")

      def epic_row(record, works)
        key = field(record, :epic).to_s
        mine = works.select { |work| field(work, :epic).to_s == key }.map { |work| field(work, :status).to_s }
        { epic: key, title: field(record, :title).to_s, outcome: field(record, :outcome).to_s,
          tier: field(record, :tier).to_s, done: mine.count("done"), dropped: mine.count("dropped") }
      end

      def run_item(run)
        { work_item: work_item_of(run), status: field(run, :status).to_s,
          run: field(run, :run).to_s, repo: field(run, :repo).to_s, agent: field(run, :agent).to_s,
          works_as: field(run, :works_as).to_s }
      end

      # The Work item a run names, else the one the first line of its brief names.
      def work_item_of(run)
        named = field(run, :work).to_s
        named.empty? ? field(run, :brief).to_s[WORK_ITEM_LINE, 1].to_s : named
      end

      def records_of(domain, name)
        bluebook = @registry&.bluebook(domain)
        aggregate = bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        raise PipelineBoard::Unavailable, "the #{domain} domain is not booted here" unless aggregate

        @registry.repository(domain, aggregate).all
      end

      def field(record, name) = StartedWork.value(record, name)
    end
  end
end
