# frozen_string_literal: true

require "json"
require_relative "probe"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `Tickets` port's adapter: answers `OpenWork` with the Work items that are not done, read
    # through the booted Tickets domain's repository (never from its database), and reports which
    # session ran each row from the AgentRun records. It only reads.
    class PipelineTickets
      DONE = %w[done dropped].freeze
      ROW_LINE = /^ROW:\s*(\S+)/
      EMPTY = "the Tickets store holds no Work items here (Memory); run the board from the main checkout"

      # @param registry [Runtime::Registry, nil] the booted registry whose rows are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `rows:` and `landings:` stand in for the registry's Work and
      #   Landing records
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standin = settings[:rows]
        @landed = settings[:landings]
      end

      # @return [Hash{Symbol => String}] `text:` the open rows as JSON: slug, status, area, and
      #   who claimed each and when
      def open_work = { text: JSON.generate(rows.reject { |row| DONE.include?(row[:status]) }) }

      # @return [Hash{String => Integer}] every Work row counted by status
      def counts = rows.map { |row| row[:status] }.tally

      # @return [Hash{String => Hash}] each AgentRun's session id with its `row` (named on the
      #   first line of its brief) and `status`
      def runs
        records_of("Hecks", "AgentRun").to_h { |run| [field(run, :session).to_s, run_row(run)] }
      end

      # @return [Array<String>] the branches the Landing records say were merged onto main, with any
      #   leading `qa/` taken off
      def landed_branches
        landings = @landed || records_of("Hecks", "Landing")
        landed = landings.select { |land| field(land, :status).to_s == "landed" }
        landed.map { |land| field(land, :branch).to_s.delete_prefix("qa/") }
      end

      private

      def rows
        found = @standin || records_of("Tickets", "Work").map { |record| row(record) }
        raise PipelineBoard::Unavailable, EMPTY if found.empty?

        found
      end

      def row(record)
        { slug: field(record, :work).to_s, status: field(record, :status).to_s, title: field(record, :title).to_s,
          area: StartedWork.words(field(record, :area)), claimed_by: field(record, :claimed_by).to_s,
          claimed_at: field(record, :claimed_at).to_s }
      end

      def run_row(run) = { row: field(run, :brief).to_s[ROW_LINE, 1].to_s, status: field(run, :status).to_s }

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
