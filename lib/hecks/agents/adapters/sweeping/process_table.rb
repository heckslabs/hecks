# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      # The spare daemons in the process table: each `bg-pty-host` spawned for a spare, with
      # the processes it runs. A claimed spare keeps its command line, so a host alone does not say
      # whether a session lives in it; {SpareTrace} and the session list do.
      class ProcessTable
        # One process of the table.
        Entry = Struct.new(:pid, :ppid, :age, :rss_kb, :command)

        HOST = %r{--bg-pty-host \S*/spare/[0-9a-f]+\.pty\.sock}
        BLANKS = /\s+/

        # @param shell [#capture] runs `ps`
        # @param now [Time] what ages are counted back from
        def initialize(shell:, now: Time.now)
          @shell = shell
          @now = now
        end

        # @return [Array<Entry>] every process
        def entries
          result = @shell.capture("ps", "-axo", "pid=,ppid=,etime=,rss=,command=")
          return [] unless result.ok?

          result.out.lines.filter_map { |line| entry(line) }
        end

        # @return [Array<Entry>] the hosts spawned for spares
        def hosts = entries.select { |entry| entry.command.match?(HOST) }

        # @return [Array<Entry>] the processes below +pid+, nearest first
        def below(pid, table = entries)
          kids = table.select { |entry| entry.ppid == pid }
          kids + kids.flat_map { |kid| below(kid.pid, table) }
        end

        # @return [Array<Entry>] every spare daemon process: hosts and what they run
        def spare_processes
          table = entries
          hosts = table.select { |entry| entry.command.match?(HOST) }
          (hosts + hosts.flat_map { |host| below(host.pid, table) }).uniq(&:pid)
        end

        # @param entry [Entry] a process
        # @return [Time] when a process of that age started
        def started(entry) = @now - entry.age

        private

        def entry(line)
          pid, ppid, etime, rss, command = line.strip.split(BLANKS, 5)
          return nil unless command

          Entry.new(pid.to_i, ppid.to_i, seconds(etime), rss.to_i, command)
        end

        def seconds(etime)
          days, clock = etime.include?("-") ? etime.split("-", 2) : [0, etime]
          parts = clock.split(":").map(&:to_i)
          parts.unshift(0) while parts.length < 3
          (days.to_i * 86_400) + (parts[0] * 3600) + (parts[1] * 60) + parts[2]
        end
      end
    end
  end
end
