# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `LandedWork` port's adapter for `Tickets::Work`: finds the open work item a landed branch
    # was
    # cut for, so the bluebook can finish it.
    #
    # A branch names its work item by the whole branch name, else by the name without a leading
    # `qa/`
    # (QA's branches carry that prefix, the work items they close do not). Only a `planned` or
    # `started`
    # work item is found; a branch with no work item, or one already done or dropped, is refused by
    # name and
    # the bluebook reacts to neither. It writes nothing.
    class LandedWork
      # The prefix QA puts on a branch whose work item carries the bare name.
      QA_PREFIX = "qa/"

      # What opens each landing refusal recorded in a work item's detail.
      REFUSED = "Landing refused: "

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @param held [Hash] the landing's `branch`
      # @return [Hash{Symbol => Hash}] `branch:` the key of the open work item the branch names
      # @raise [ConsoleCapture::Failure] when no open work item is named by the branch
      def find_landed_work(**held)
        branch = plain(held[:branch]).to_s
        found = (candidates(branch) & open_keys).first
        raise ConsoleCapture::Failure, "no open work item is named #{branch}" unless found

        { branch: { value: found } }
      end

      # Finds the finished work item a refused landing job's branch names. It judges nothing:
      # whether the item is planned again is the Tickets bluebook's, from the count answered here.
      #
      # @param held [Hash] the `Landing` record's `branch`, and the `refusal` its job was given
      # @return [Hash{Symbol => Hash}] `work:` the item's key, `title:` its title, `detail:` its
      #   detail ending with the refusal, `refusals:` how many landing refusals the detail held
      # @raise [ConsoleCapture::Failure] when no finished work item is named by the branch
      def find_refused_work(**held)
        branch = plain(held[:branch]).to_s
        item = finished.find { |record| candidates(branch).include?(StartedWork.value(record, :work).to_s) }
        raise ConsoleCapture::Failure, "no finished work item is named #{branch}" unless item

        refused(item, plain(held[:refusal]).to_s)
      end

      private

      def refused(item, refusal)
        detail = StartedWork.value(item, :detail).to_s
        { work:     { value: StartedWork.value(item, :work).to_s },
          title:    { value: StartedWork.value(item, :title).to_s },
          detail:   { value: [detail, "#{REFUSED}#{refusal}"].reject(&:empty?).join("\n\n") },
          refusals: { value: detail.scan(REFUSED).size } }
      end

      def finished
        aggregate = StartedWork.work_aggregate(@registry)
        return [] unless aggregate

        @registry.repository("Tickets", aggregate).all.select { |item| StartedWork.value(item, :status) == "done" }
      end

      def candidates(branch) = [branch, branch.delete_prefix(QA_PREFIX)].reject(&:empty?).uniq

      def open_keys
        aggregate = StartedWork.work_aggregate(@registry)
        return [] unless aggregate

        records = @registry.repository("Tickets", aggregate).all
        records.select { |item| %w[planned started].include?(StartedWork.value(item, :status)) }
               .map { |item| StartedWork.value(item, :work).to_s }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
