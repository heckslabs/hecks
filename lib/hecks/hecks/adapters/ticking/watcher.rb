# frozen_string_literal: true

module Hecks
  module Adapters
    class Ticking
      # One child process that waits on a pull request's checks (`gh pr checks <branch> --watch`)
      # for the chain, so its exit is the event and no tick is booted while it runs. A child that
      # exits at once, or cannot start, did not watch: the chain ticks on its own schedule instead.
      class Watcher
        # Seconds under which an exit counts as a failure to watch (no checks yet, no `gh`).
        FAILED_UNDER = 5

        # @param branch [String] the pull request's branch
        # @param clock [#call] returns the time
        # @param spawn [#call] starts the argument list and returns a pid
        # @param reap [#call] takes a pid, returns true once it has exited
        def initialize(branch, clock:, spawn: nil, reap: nil)
          @command = ["gh", "pr", "checks", branch, "--watch"]
          @clock = clock
          @spawn = spawn || method(:detach)
          @reap = reap || method(:exited?)
          @state = :idle
        end

        # @return [Symbol] `:idle` (not started), `:running`, `:done` (watched, ended) or `:failed`
        attr_reader :state

        # Starts the child once.
        # @return [Symbol] the state
        def start
          @pid = @spawn.call(*@command)
          @began = @clock.call
          @state = :running
        rescue SystemCallError
          @state = :failed
        end

        # @return [Symbol] the state, moved on when the child has exited
        def poll
          return @state unless @state == :running && @reap.call(@pid)

          @state = @clock.call - @began < FAILED_UNDER ? :failed : :done
        end

        # Ends a child still running.
        def stop
          Process.kill("TERM", @pid) if @state == :running
        rescue SystemCallError
          nil
        end

        private

        def detach(*argv) = Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL)

        def exited?(pid) = !Process.wait2(pid, Process::WNOHANG).nil?
      end
    end
  end
end
