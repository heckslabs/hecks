# frozen_string_literal: true

require_relative "orphans/rules"
require_relative "orphans/halting"
require_relative "orphans/directories"

module Hecks
  module Adapters
    class Sweeping
      # What a launcher or a push rehearsal left running with nobody waiting for it: an `exe/hecks`
      # process older than half an hour whose parent is init or gone, and a rehearsal's push (its
      # processes and its temp directory) older than a day. It reads the process table and the temp
      # directories; {#reap} stops the processes and deletes the directories.
      #
      # {Rules} says what counts. A server, a tick, a gate, a spec run and a wait on an event stay:
      # they run detached or long on purpose. So does the sweep's own process and everything above
      # it.
      class Orphans
        VERDICTS = {
          stopped: "stopped", still_running: "still running", reused: "left alone, the pid was reused",
          denied: "not stopped, permission denied"
        }.freeze

        # @param table [ProcessTable] the process table
        # @param killer [#call] called with a pid to stop it
        # @param tmp [String, Array<String>] the temp directories holding rehearsal directories
        # @param now [Time] what directory ages are counted back from
        # @param pause [#call] waits a moment for stopped processes to exit
        def initialize(table:, killer:, tmp:, now: Time.now, pause: -> { sleep(0.3) })
          @table = table
          @killer = killer
          @pause = pause
          @directories = Directories.new(roots: Array(tmp), marker: Rules::FIXTURE, age: Rules::FIXTURE_AGE,
                                         now: now, cwds: -> { table.working_directories })
        end

        # @return [Array<String>] a line for each leftover, changing nothing
        def lines
          rules.leftovers.map { |entry| describe("leftover", entry) } +
            @directories.stale.map { |path| "stale push directory  #{path}" }
        end

        # Stops the leftover processes and deletes the stale directories.
        # @return [Array<String>] a line for each action taken
        def reap
          outcome = Halting.new(table: @table, killer: @killer, pause: @pause).call(rules.stoppable)
          rules.leftovers.map { |entry| describe(VERDICTS.fetch(outcome.fetch(entry.pid, :stopped)), entry) } +
            @directories.stale.map { |path| @directories.delete(path) }
        end

        private

        def rules = (@rules ||= Rules.new(table: @table, entries: @table.entries))

        def describe(kind, entry) = "#{kind}  pid=#{entry.pid}  age=#{entry.age}s  #{entry.command[0, 120]}"
      end
    end
  end
end
