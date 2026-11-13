# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineSampling
      class ProcessClasses
        # The session each process of a table runs under, read up its parent chain: the nearest
        # ancestor that a daemon log names as a claimed spare host gives the session.
        class Owners
          # @param table [Array<Entry>] every process
          # @param claims [#call] answers a daemon log's claims as `{host pid => session}`
          def initialize(table, claims)
            @table = table
            @by_pid = table.to_h { |entry| [entry.pid, entry] }
            @claims = claims
          end

          # @return [Hash{Array(String, String) => Array<Entry>}] the processes by class and session
          def grouped = @table.group_by { |entry| [name(entry), session(entry)] }

          private

          # The program's name: the command line's first word without its directory.
          def name(entry)
            program = entry.command.split(BLANKS).first
            File.basename(program.to_s)
          end

          # The session of the nearest claimed host above the process; empty when there is none.
          def session(entry)
            claimed = hosts
            chain(entry).each { |pid| return claimed[pid] if claimed.key?(pid) }
            ""
          end

          # Every pid above the process, nearest first, stopping at a loop or at launchd.
          def chain(entry)
            pids = []
            pid = entry.pid
            while (current = @by_pid[pid]) && !pids.include?(pid)
              pids << pid
              pid = current.ppid
            end
            pids
          end

          # The claimed hosts of every daemon's log in the table, read once.
          def hosts
            @hosts ||= logs.map { |log| @claims.call(log) }.reduce({}, :merge)
          end

          def logs = @table.filter_map { |entry| entry.command[DAEMON_LOG, 1] }.uniq
        end
      end
    end
  end
end
