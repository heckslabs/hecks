# frozen_string_literal: true

require_relative "purposes"

module Hecks
  module Adapters
    class MachineSampling
      # The CPU of a process table summed by purpose, busiest first: the percent of one core each
      # purpose uses, and the busiest command under it. It reads a table and changes nothing.
      class Consumers
        TOP = 5

        # @param entries [Array<ProcessClasses::Entry>] every process
        def initialize(entries)
          @entries = entries
        end

        # @return [Array<Hash>] `purpose`, `cpu` and `top` (the busiest command's program) per
        #   purpose, at most five, busiest first
        def rows
          groups = @entries.group_by { |entry| Purposes.of(entry.command) }
          groups.map { |purpose, group| row(purpose, group) }.sort_by { |row| -row[:cpu] }.first(TOP)
        end

        private

        def row(purpose, group)
          { purpose: purpose, cpu: group.sum(&:cpu).round(1), top: program(group.max_by(&:cpu)) }
        end

        # The program's name of a process: its command's first word without its directory.
        def program(entry)
          first = entry.command.split.first
          File.basename(first.to_s)
        end
      end
    end
  end
end
