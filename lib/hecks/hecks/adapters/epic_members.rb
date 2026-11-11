# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"

module Hecks
  module Adapters
    # The members of one `Tickets::Epic`: the `Tickets::Work` items whose epic names it, read from a
    # booted registry. The `EpicMembers` port's adapter and the `EpicProgress` adapter both count
    # through this; it reads and never writes.
    module EpicMemberRows
      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; nil reads no work items
      # @param epic [String] the epic's key
      # @return [Array<Hash{Symbol => Object}>] `key:`, `status:` and `step:` of each member
      def of(registry, epic)
        aggregate = StartedWork.work_aggregate(registry)
        return [] unless aggregate

        rows = registry.repository("Tickets", aggregate).all.map { |record| row(record) }
        rows.select { |member| member[:epic] == epic.to_s }
      end

      # @return [Hash] a work item's key, epic, status and step as plain values
      def row(record)
        fields = %i[work epic status step].to_h { |name| [name, StartedWork.value(record, name)] }
        fields.merge(key: fields[:work].to_s, epic: fields[:epic].to_s)
      end
    end

    # The `EpicMembers` port's adapter for `Tickets::Epic`: whether an epic has a member and none
    # planned or started.
    #
    # It decides nothing about what happens next: the bluebook completes the epic on the answer.
    class EpicMembers
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # Clears an epic whose members are all closed.
      #
      # @param held [Hash] the Epic: `epic`
      # @return [Hash{Symbol => Hash}] `output:` the line that says the members are closed
      # @raise [ConsoleCapture::Failure] when the epic has no member or one is planned or started
      def check_members(**held)
        key = held[:epic].is_a?(Hash) ? held[:epic][:value] : held[:epic]
        members = EpicMemberRows.of(@registry, key)
        open = members.select { |member| %w[planned started].include?(member[:status]) }
        raise ConsoleCapture::Failure, "#{key} has no member" if members.empty?
        raise ConsoleCapture::Failure, "#{key} has #{open.size} open member(s)" unless open.empty?

        { members: { value: members.size }, open_members: { value: 0 } }
      end
    end
  end
end
