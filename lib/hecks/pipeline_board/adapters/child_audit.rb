# frozen_string_literal: true

require "time"
require_relative "../../hecks/adapters/shell"

module Hecks
  module Adapters
    module PipelineBoard
      # Names and reaps the board's own defunct children. A child that has exited and was never
      # waited on stays in the process table as a zombie, and `ps` then shows its command as
      # `<defunct>`, so the audit remembers the last command each child ran while it was live and
      # reports that beside the pid once the child is seen defunct on {ChildAudit::READS} reads in
      # a row. A waiter reaps its child within moments of its exit, so a child still defunct after
      # that many reads has none, and the audit then waits on it itself. That is a last resort that
      # bounds the leak; it never signals a process, and a waiter that does come late finds the
      # child gone (`ECHILD`).
      class ChildAudit
        # Consecutive reads a child must be defunct before it is reported, so one that is only
        # between its exit and its waiter is not.
        READS = 2

        # The blanks between the columns of a `ps` line.
        BLANKS = /\s+/

        # One row of the process table.
        Row = Struct.new(:pid, :ppid, :stat, :command)

        # @param rows [#call, nil] answers the table as {Row}s; `ps` when nil
        # @param parent [Integer] the process whose children are audited
        # @param log [#call] takes one line to report
        # @param now [#call] answers the current time
        # @param reap [#call] takes the pid of a child to wait on without blocking
        def initialize(rows: nil, parent: Process.pid, log: ->(line) { warn(line) }, now: -> { Time.now.utc },
                       reap: ->(pid) { self.class.reap(pid) })
          @rows = rows || -> { self.class.table }
          @reap = reap
          @parent = parent
          @log = log
          @now = now
          @argv = {}
          @reads = Hash.new(0)
        end

        # @return [Array<Row>] every process, empty when `ps` fails
        def self.table
          result = Shell.new.capture("ps", "-axo", "pid=,ppid=,stat=,command=")
          return [] unless result.ok?

          result.out.lines.filter_map { |line| row(line) }
        end

        # Waits on a child that has exited, without blocking.
        #
        # @param pid [Integer] the child's pid
        # @return [Integer, nil] the pid when it was reaped; nil when it is already gone
        def self.reap(pid)
          Process.wait(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end

        # @param line [String] one line of `ps -o pid=,ppid=,stat=,command=`
        # @return [Row, nil] the process, nil for a line with no command
        def self.row(line)
          pid, ppid, stat, command = line.strip.split(BLANKS, 4)
          command && Row.new(pid.to_i, ppid.to_i, stat, command)
        end

        # Reads the table once, logs each child that has just reached {ChildAudit::READS} defunct
        # reads, then reaps each child that has reached them, the one just logged included.
        #
        # @return [Array<Integer>] the pids of the board's children that are defunct now
        def read
          children = @rows.call.select { |row| row.ppid == @parent }
          remember(children)
          dead = children.select { |row| defunct?(row) }
          count(dead)
          dead.each { |row| settle(row) }
          dead.map(&:pid)
        end

        private

        def settle(row)
          report(row) if @reads[row.pid] == READS
          @reap.call(row.pid) if @reads[row.pid] >= READS
        end

        def defunct?(row) = row.stat.to_s.start_with?("Z")

        def remember(children)
          @argv.merge!(children.reject { |row| defunct?(row) }.to_h { |row| [row.pid, row.command] })
          pids = children.map(&:pid)
          @argv.select! { |pid, _| pids.include?(pid) }
        end

        def count(dead)
          pids = dead.map(&:pid)
          @reads.select! { |pid, _| pids.include?(pid) }
          pids.each { |pid| @reads[pid] += 1 }
        end

        def report(row)
          argv = @argv.fetch(row.pid, "never seen live")
          @log.call("board: defunct child pid=#{row.pid} seen #{READS} reads running=#{argv} at=#{@now.call.iso8601}")
        end
      end
    end
  end
end
