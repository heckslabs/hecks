# frozen_string_literal: true

require_relative "../shell"
require "hecks/agents/adapters/sweeping/spare_trace"

module Hecks
  module Adapters
    class MachineSampling
      # The machine's processes grouped by class (the program's name) and by the background
      # session whose shell they run under, busiest first by summed CPU. It reads `ps` and the
      # claude daemon's log and changes nothing: it never stops a process or a session.
      #
      # A process's session is found up its parent chain: the chain passes a spare host that the
      # daemon's log says a session claimed, and ends at the daemon, whose own command line names
      # that log (`--log-file`), so no path is assumed.
      class ProcessClasses
        # One process of the table.
        Entry = Struct.new(:pid, :ppid, :cpu, :command)

        BLANKS = /\s+/
        DAEMON_LOG = /\bdaemon run\b.*--log-file (\S+)/
        TOP = 10

        # @param entries [#call, nil] answers the table as {Entry} rows; `ps` when nil
        # @param claims [#call, nil] answers a daemon log's claims as `{host pid => session}`;
        #   the log's `claimed-spare` lines when nil
        def initialize(entries: nil, claims: nil)
          @entries = entries || -> { self.class.table(Shell.new) }
          @claims = claims || ->(log) { Sweeping::SpareTrace.new(log: log).claims.transform_values(&:session) }
        end

        # @param shell [#capture] runs `ps`
        # @return [Array<Entry>] every process, empty when `ps` fails
        def self.table(shell)
          result = shell.capture("ps", "-axo", "pid=,ppid=,pcpu=,command=")
          return [] unless result.ok?

          result.out.lines.filter_map { |line| entry(line) }
        end

        # @param line [String] one line of `ps -o pid=,ppid=,pcpu=,command=`
        # @return [Entry, nil] the process, nil for a line with no command
        def self.entry(line)
          pid, ppid, cpu, command = line.strip.split(BLANKS, 4)
          command && Entry.new(pid.to_i, ppid.to_i, cpu.to_f, command)
        end

        # @param top [Integer] how many classes to keep
        # @return [Array<Hash>] `name`, `count`, `cpu` (summed percent) and `session` (empty when
        #   no claimed host is above it) per class, busiest first
        def rows(top: TOP) = classes.sort_by { |row| -row[:cpu] }.first(top)

        # @return [String] the busiest class in one line; "Busiest: unknown" when `ps` said nothing
        def line
          busiest = rows(top: 1).first
          return "Busiest: unknown" unless busiest

          owner = busiest[:session].empty? ? "no pipeline session" : "session #{busiest[:session]}"
          "Busiest: #{busiest[:name]} x#{busiest[:count]}, #{busiest[:cpu]}% CPU, #{owner}"
        end

        private

        # One row per class and owner, in no order.
        def classes
          groups = Owners.new(@entries.call, @claims).grouped
          groups.map { |(name, session), group| row(name, session, group) }
        end

        def row(name, session, group)
          { name: name, count: group.length, cpu: group.sum(&:cpu).round(1), session: session }
        end
      end
    end
  end
end

require_relative "process_classes/owners"
