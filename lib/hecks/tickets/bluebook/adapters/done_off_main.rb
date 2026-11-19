# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/branch_work_names"
require_relative "done_off_main/unlanded"

module Hecks
  module Adapters
    # The `DoneOffMain` port's adapter for `Tickets::Work`: lists the local branches that name a
    # done work item and whose tip `main` does not contain.
    #
    # It also lists, as `key - -`, each done item that no landed `Landing` names and that records
    # neither a landing nor a no-change reason ({Unlanded}): marked done with nothing on main.
    #
    # It states facts and judges nothing. A git failure (no `main`, no repository) is refused by
    # name, never answered as an empty list. It reads and never writes.
    class DoneOffMain
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `root:` the checkout whose branches are read (the working directory
      #   when absent)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @checkout = settings[:root]
        @git = Git.new
      end

      # @return [Hash{Symbol => String}] `text:` one `key branch tip` line per such branch, then one
      #   `key - -` line per unlanded done item, each ending in a newline; empty when none
      # @raise [ConsoleCapture::Failure] when git cannot answer
      def done_off_main(**)
        found = branches.filter_map { |branch, tip| line(branch, tip) unless merged?(tip) }
        found += Unlanded.new(@registry).keys(done_records, keys).map { |key| "#{key} - -" }
        { text: found.map { |text| "#{text}\n" }.join }
      end

      private

      def line(branch, tip)
        key = (BranchWorkNames.of(branch, keys) & done).first
        "#{key} #{branch} #{tip[0, 9]}" if key
      end

      def merged?(tip) = @git.ancestor?(tip, "main", chdir: @checkout)

      def branches
        listed = @git.capture("for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads", chdir: @checkout)
        raise ConsoleCapture::Failure, "git for-each-ref failed: #{listed.err.strip}" unless listed.ok?

        pairs(listed.out)
      end

      def pairs(printed) = printed.lines.map(&:split).select { |pair| pair.size == 2 }

      def keys = records.map { |record| StartedWork.value(record, :work).to_s }

      def done = done_records.map { |record| StartedWork.value(record, :work).to_s }

      def done_records = records.select { |record| StartedWork.value(record, :status).to_s == "done" }

      def records
        @records ||= StartedWork.work_aggregate(@registry).then do |aggregate|
          aggregate ? @registry.repository("Tickets", aggregate).all : []
        end
      end
    end
  end
end
