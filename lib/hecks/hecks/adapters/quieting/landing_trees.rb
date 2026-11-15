# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class Quieting
      # The landings in flight, found in the process table and ended with everything beneath them.
      #
      # Stopping a session does not end its landing: a landing runs on after the session that asked
      # for it is gone, under a wrapper whose parent is `launchd`, and its gate starts spec runs
      # that
      # carry no worktree name. So the landing is found by what it is called, and what it started is
      # found by who its parent is, repeating until nothing is left. Nothing here touches a branch,
      # a commit or a worktree.
      class LandingTrees
        # What a landing's own process is called, the wrapper that carries a detached one included.
        ROOTS = /Landing\.(?:carry|finish)!|landing\.finish!|launcher, flag/

        # One row of `ps -axo pid=,ppid=,command=`.
        ROW = /\A\s*(\d+)\s+(\d+)\s+(.*)\z/

        # @param table [#call, nil] answers the process table as text, one `pid ppid command` row
        #     each
        # @param kill [#call, nil] ends one process by its number
        # @param rounds [Integer] how many times to look again after ending what was found
        # @param pause [Numeric] seconds between those rounds
        # @param own [Array<Integer>] the asking processes: they and the ones above them are never
        #   ended
        def initialize(table: nil, kill: nil, rounds: 4, pause: 1, own: nil)
          @table = table || method(:process_table)
          @kill = kill || method(:end_process)
          @rounds = rounds
          @pause = pause
          @own = own || [Process.pid, Process.ppid]
        end

        # @param rows [Array<Array(Integer, Integer, String)>] `pid`, `ppid` and command of each
        #   process
        # @return [Array<Integer>] each landing process and every process beneath it, except the
        #   asking process and the ones above it
        def victims(rows)
          parents = rows.to_h { |pid, ppid, _| [pid, ppid] }
          shielded = shield(parents)
          roots = rows.select { |pid, _, command| ROOTS.match?(command) && !shielded.include?(pid) }.map(&:first)
          beneath(roots, rows.group_by { |_, ppid, _| ppid }, shielded)
        end

        # Ends every landing in flight and everything it started, until none is left.
        #
        # @return [Array<Integer>] every process that was ended
        def end_all
          ended = []
          @rounds.times do
            found = victims(rows)
            break if found.empty?

            found.each { |pid| @kill.call(pid) }
            ended.concat(found)
            sleep(@pause)
          end
          ended.uniq
        end

        private

        def beneath(roots, children, shielded)
          seen = roots.dup
          queue = roots.dup
          until queue.empty?
            (children[queue.shift] || []).each do |pid, _, _|
              next if seen.include?(pid) || shielded.include?(pid)

              seen << pid
              queue << pid
            end
          end
          seen
        end

        # The processes never ended: the asking one and every one above it, up to the first.
        def shield(parents)
          @own.flat_map do |pid|
            chain = []
            while pid && !chain.include?(pid)
              chain << pid
              pid = parents[pid]
            end
            chain
          end.uniq
        end

        def table_text = @table.call.to_s

        def rows = table_text.lines.filter_map { |line| row(line) }

        def row(line)
          match = ROW.match(line.chomp)
          [match[1].to_i, match[2].to_i, match[3]] if match
        end

        def process_table = Shell.new.capture("ps", "-axo", "pid=,ppid=,command=").out

        def end_process(pid)
          Process.kill("KILL", pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end
  end
end
