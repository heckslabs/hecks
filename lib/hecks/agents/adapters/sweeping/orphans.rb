# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    class Sweeping
      # What a launcher or a push rehearsal left running with nobody waiting for it: an `exe/hecks`
      # process older than ten minutes whose parent is init or gone, and a rehearsal's isolated
      # push (its processes and its temp directory) older than a day. It reads the process table
      # and the temp directory; {#reap} stops the processes and deletes the directories.
      #
      # A server stays: the board, a served page, an MCP server and the push train run detached on
      # purpose. So does the sweep's own process and everything above it.
      class Orphans
        # How long an unattended launcher may run before it is a leftover, in seconds.
        LAUNCHER_AGE = 600
        # How long an isolated push may stay before it is a leftover, in seconds.
        FIXTURE_AGE = 86_400
        # A launcher process: the binary run directly or under `ruby`.
        LAUNCHER = %r{(\A|[\s/])exe/hecks(\s|\z)}
        # Launchers that run detached on purpose.
        KEPT = /serve!|present!|compose!|preview!|\bmcp\b|mcp!|SendTrain|send_train/
        # The marker a push rehearsal puts in its temp directory and in its processes' command lines.
        FIXTURE = "hecks-isolated-push"
        # The git push that started a rehearsal names no path, so it is found through its children.
        PUSH = /\Agit\b/

        # @param table [ProcessTable] the process table
        # @param killer [#call] called with a pid to stop it
        # @param tmp [String] the temp directory holding rehearsal directories
        # @param now [Time] what directory ages are counted back from
        def initialize(table:, killer:, tmp:, now: Time.now)
          @table = table
          @killer = killer
          @tmp = tmp
          @now = now
        end

        # @return [Array<String>] a line for each leftover, changing nothing
        def lines
          leftovers.map { |entry| describe("leftover", entry) } + directories.map { |path| "stale push directory  #{path}" }
        end

        # Stops the leftover processes and deletes the stale directories.
        # @return [Array<String>] a line for each action taken
        def reap
          stoppable.each { |entry| halt(entry) }
          leftovers.map { |entry| describe("stopped", entry) } + directories.map { |path| delete(path) }
        end

        private

        def leftovers = launchers + fixtures

        def stoppable = leftovers.flat_map { |entry| [entry] + @table.below(entry.pid, entries) }.uniq(&:pid)

        def launchers
          alive = entries.map(&:pid)
          entries.select { |entry| launcher?(entry) && unattended?(entry, alive) }
        end

        def launcher?(entry)
          entry.command.match?(LAUNCHER) && !entry.command.match?(KEPT) && entry.age > LAUNCHER_AGE
        end

        def unattended?(entry, alive) = (entry.ppid == 1 || !alive.include?(entry.ppid)) && !mine.include?(entry.pid)

        def fixtures
          found = entries.select { |entry| entry.command.include?(FIXTURE) && entry.age > FIXTURE_AGE }
          (found + pushes(found)).uniq(&:pid).reject { |entry| mine.include?(entry.pid) }
        end

        def pushes(found)
          entries.select { |entry| entry.command.match?(PUSH) && found.any? { |kid| kid.ppid == entry.pid } }
        end

        def directories
          Dir.glob(File.join(@tmp, "#{FIXTURE}*")).select { |path| stale?(path) }
        end

        def stale?(path) = File.directory?(path) && !File.symlink?(path) && @now - File.mtime(path) > FIXTURE_AGE

        def halt(entry)
          @killer.call(entry.pid)
        rescue Errno::ESRCH
          nil
        end

        def delete(path)
          FileUtils.remove_entry(path)
          "deleted push directory  #{path}"
        end

        def describe(kind, entry) = "#{kind}  pid=#{entry.pid}  age=#{entry.age}s  #{entry.command[0, 120]}"

        def entries = (@entries ||= @table.entries)

        def mine
          @mine ||= ancestry([Process.pid])
        end

        def ancestry(chain)
          parent = entries.find { |entry| entry.pid == chain.last }&.ppid
          parent && parent > 1 && !chain.include?(parent) ? ancestry(chain + [parent]) : chain
        end
      end
    end
  end
end
