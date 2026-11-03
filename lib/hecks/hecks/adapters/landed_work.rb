# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `LandedWork` port's adapter for `Tickets::Work`: finds the open step a landed branch was
    # cut for, so the bluebook can finish it.
    #
    # A branch names its step by the whole branch name, else by the name without a leading `qa/`
    # (QA's branches carry that prefix, the steps they close do not). Only a `planned` or `started`
    # step is found; a branch with no step, or one already done or dropped, is refused by name and
    # the bluebook reacts to neither. It writes nothing.
    class LandedWork
      # The prefix QA puts on a branch whose step carries the bare name.
      QA_PREFIX = "qa/"

      # @param registry [Runtime::Registry, nil] the booted registry whose Work rows are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @param held [Hash] the landing's `branch`
      # @return [Hash{Symbol => Hash}] `branch:` the key of the open step the branch names
      # @raise [ConsoleCapture::Failure] when no open step is named by the branch
      def find_landed_work(**held)
        branch = plain(held[:branch]).to_s
        found = (candidates(branch) & open_keys).first
        raise ConsoleCapture::Failure, "no open step is named #{branch}" unless found

        { branch: { value: found } }
      end

      private

      def candidates(branch) = [branch, branch.delete_prefix(QA_PREFIX)].reject(&:empty?).uniq

      def open_keys
        aggregate = StartedWork.work_aggregate(@registry)
        return [] unless aggregate

        records = @registry.repository("Tickets", aggregate).all
        records.select { |row| %w[planned started].include?(StartedWork.value(row, :status)) }
               .map { |row| StartedWork.value(row, :work).to_s }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
