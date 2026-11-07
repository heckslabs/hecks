# frozen_string_literal: true

require "json"
require_relative "probe"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `Tickets` port's adapter: answers `OpenWork` with the Work items that are not done, read
    # through the booted Tickets domain's repository (never from its database), and reports which
    # session ran each work item from the AgentRun records. It only reads.
    class PipelineTickets
      DONE = %w[done dropped].freeze
      WORK_ITEM_LINE = /^(?:WORK ITEM|ROW):\s*(\S+)/
      # How long the runs read stays good: the jobs reader asks for them once per session.
      RUNS_TTL = 20
      EMPTY = "the Tickets store holds no Work items here (Memory); run the board from the main checkout"

      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `work_items:` and `landings:` stand in for the registry's Work and
      #   Landing records
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standin = settings[:work_items]
        @landed = settings[:landings]
      end

      # @return [Hash{Symbol => String}] `text:` the open work items as JSON: slug, status, area,
      #   and
      #   who claimed each and when
      def open_work = { text: JSON.generate(items.reject { |item| DONE.include?(item[:status]) }) }

      # @return [Hash{String => Integer}] every Work item counted by status
      def counts = items.map { |item| item[:status] }.tally

      # @return [Hash{String => Hash}] each AgentRun's session id with its `work_item` (named on the
      #   first line of its brief) and `status`
      def runs
        return @runs_held[:value] if @runs_held && Time.now - @runs_held[:at] < RUNS_TTL

        @runs_held = { at: Time.now, value: run_records.to_h { |run| [field(run, :session).to_s, run_item(run)] } }
        @runs_held[:value]
      end

      # The AgentRun records: the launcher's running and finished runs when the board is told where
      # the live store is, else the booted registry's.
      def run_records
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
        return records_of("Hecks", "AgentRun") if root.empty?

        %w[AgentRun.running AgentRun.tidyable].flat_map do |query|
          PipelineBoard::Probe.json("exe/hecks", query, chdir: root).map { |row| row.transform_keys(&:to_sym) }
        end
      end

      # @return [Array<String>] the branches the Landing records say were merged onto main, with any
      #   leading `qa/` taken off
      def landed_branches
        landings = @landed || records_of("Hecks", "Landing")
        landed = landings.select { |land| field(land, :status).to_s == "landed" }
        landed.map { |land| field(land, :branch).to_s.delete_prefix("qa/") }
      end

      private

      def items
        found = @standin || from_launcher || records_of("Tickets", "Work").map { |record| item(record) }
        raise PipelineBoard::Unavailable, EMPTY if found.empty?

        found
      end

      # The undone Work items as the launcher reads them in the checkout that holds the live
      # store, when the board is told where that is (PIPELINE_BOARD_LAUNCHER_ROOT). Nil otherwise.
      def from_launcher
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
        return nil if root.empty?

        PipelineBoard::Probe.json("exe/hecks", "tickets", "Work.undone", chdir: root).map { |row| launched(row) }
      end

      def launched(row)
        { slug: row["work"].to_s, status: row["status"].to_s, title: row["title"].to_s,
          area: Array(row["area"]).map(&:to_s), claimed_by: row["claimed_by"].to_s, claimed_at: row["claimed_at"].to_s }
      end

      def item(record)
        { slug: field(record, :work).to_s, status: field(record, :status).to_s, title: field(record, :title).to_s,
          area: StartedWork.words(field(record, :area)), claimed_by: field(record, :claimed_by).to_s,
          claimed_at: field(record, :claimed_at).to_s }
      end

      def run_item(run)
        { work_item: work_item_of(run), status: field(run, :status).to_s,
          run: field(run, :run).to_s, repo: field(run, :repo).to_s, agent: field(run, :agent).to_s }
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
