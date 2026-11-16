# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/branch_work_names"

module Hecks
  module Adapters
    # The `DoneOffMain` port's adapter for `Tickets::Work`: lists the local branches that name a
    # done work item and whose tip `main` does not contain.
    #
    # It states facts and judges nothing: a done item with no local branch has nothing to lose and
    # is not listed. A git failure (no `main`, no repository) is refused by name, never answered as
    # an empty list. It reads and never writes.
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

      # @return [Hash{Symbol => String}] `text:` one `key branch tip` line per such branch, ending
      #   in a newline, empty when none
      # @raise [ConsoleCapture::Failure] when git cannot answer
      def done_off_main(**)
        found = branches.filter_map { |branch, tip| line(branch, tip) unless merged?(tip) }
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

      def done
        records.select { |record| StartedWork.value(record, :status).to_s == "done" }
               .map { |record| StartedWork.value(record, :work).to_s }
      end

      def records
        @records ||= StartedWork.work_aggregate(@registry).then do |aggregate|
          aggregate ? @registry.repository("Tickets", aggregate).all : []
        end
      end
    end
  end
end
