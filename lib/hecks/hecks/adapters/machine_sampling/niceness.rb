# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class MachineSampling
      # How many Claude processes (the daemon and the sessions it hosts) run niced or clamped, read
      # from `ps`. macOS runs a process on the efficiency cores only when it is niced hard or its
      # priority is clamped to Background (priority 4), so one such process is a session that
      # cannot use the performance cores. It reads and counts; the bluebook says what a count means.
      class Niceness
        # One whitespace run, and one process id: the table's columns.
        BLANKS = /\s+/
        PID = /\A\d+\z/

        # One Claude process of the table.
        Row = Struct.new(:pid, :nice, :priority, :command)

        # @param shell [#capture] runs `ps`; the {Shell} when nil
        def initialize(shell: nil)
          @shell = shell || Shell.new
        end

        # @param marks [Hash{Symbol => Float}] `nice_high` and `priority_low`, see {Marks}
        # @return [Float] the Claude processes at or over `nice_high`, or at or under `priority_low`
        def count(marks)
          rows.count { |row| row.nice >= marks[:nice_high] || row.priority <= marks[:priority_low] }.to_f
        end

        # @return [Array<Row>] each Claude process; empty when `ps` fails
        def rows
          result = @shell.capture("ps", "-axo", "pid=,ni=,pri=,command=")
          return [] unless result.ok?

          result.out.lines.filter_map { |line| row(line) }
        end

        private

        def row(line)
          pid, nice, priority, command = line.strip.split(BLANKS, 4)
          return unless command && File.basename(command.split.first) == "claude" && pid.match?(PID)

          Row.new(pid.to_i, nice.to_i, priority.to_i, command)
        end
      end
    end
  end
end
