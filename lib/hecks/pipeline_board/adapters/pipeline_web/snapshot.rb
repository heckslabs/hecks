# frozen_string_literal: true

require "time"
require "json"
require "digest"
require_relative "../board_restart"
require_relative "../load_guard"
require_relative "../../../hecks/adapters/dispatching/settings"

module Hecks
  module Adapters
    module PipelineBoard
      # The state the page shows, read in the background and held, so a request is answered at once
      # and a slow read never holds a page. Without the background thread it reads when asked.
      # A read that raises is recorded and the next one is tried, and the held state says how old it
      # is (`stale_seconds`), so a frozen board shows as one. Each held state carries a `version`
      # that moves only when the state does, so a reader tells a change without comparing states.
      # While the machine is loaded (see {LoadGuard}) it reads at the slower `loaded_every` period,
      # and a wake does not bring a read forward.
      class Snapshot
        WAITING = { unknown: "the first read is still in progress" }.freeze
        STALE_AFTER = 2

        # A snapshot read at the Hecks world's `board_restart` period, that restarts the board
        # when it has grown or stood too long, and stands the process's load guard when it starts.
        #
        # @param source [#call] answers the state hash
        # @param registry [Runtime::Registry, nil] whose worlds declare the limits
        # @param settings [Hash] `background:`, `restart:` (a {BoardRestart} stand-in) and
        #   `load_guard:` (a {LoadGuard} stand-in, or false for none)
        # @return [Snapshot]
        def self.kept_small(source:, registry:, settings:)
          limits = BoardRestart.limits(registry)
          restart = settings.fetch(:restart) { BoardRestart.new(limits: limits) }
          new(source: source, background: settings.fetch(:background, true), every: limits[:refresh_seconds],
              after_read: restart.method(:check), loaded_every: limits[:loaded_refresh_seconds],
              stand: standing(registry, settings.fetch(:load_guard, true)))
        end

        # What stands the guard when the snapshot starts: the stand-in when one is given, none for
        # false, else the process's own, whose limit is the load a fill stops at.
        #
        # @param registry [Runtime::Registry, nil] whose Tickets world sets `dispatch_max_load`
        # @param given [LoadGuard, Boolean] the `load_guard:` setting
        # @return [#call] answers the guard, or nil
        def self.standing(registry, given)
          return -> { given || nil } unless given == true

          -> { LoadGuard.stand(Dispatching::Settings.new(registry).max_load) }
        end

        # @param source [#call] answers the state hash
        # @param every [Numeric] seconds between reads
        # @param background [Boolean] read on a thread, not on request
        # @param now [#call] answers the current time
        # @param pace [Hash] `after_read:` runs after each read, such as the check that restarts a
        #   board grown too large; `loaded_every:` is the seconds between reads while the machine
        #   is loaded (`every` when none is given); `stand:` answers the load guard, or nil, when
        #   the snapshot starts; `wait:` stands in for the sleep that holds a loaded machine's read
        def initialize(source:, every: 30, background: true, now: -> { Time.now.utc }, **pace)
          @source = source
          @every = every
          @pace = { loaded_every: every }.merge(pace.compact)
          @background = background
          @now = now
          @lock = Mutex.new
          @wake = Queue.new
          @started_at = now.call
          @version = 0
        end

        # Starts the reading thread when the snapshot is a background one.
        # @return [Snapshot] self
        def start
          @guard = @pace[:stand]&.call
          @thread = Thread.new { refresh_forever } if @background
          self
        end

        # Reads the state again now, rather than at the next interval, so a change the board just
        # made (a reply) shows at once. On a loaded machine the read waits out its period.
        # @return [void]
        def refresh_now
          @wake << :now if @background
        end

        # Stops the reading thread.
        def stop = @thread&.kill

        # @return [Hash] the latest state with `stale_seconds` (age of the last good read), `stale`
        #   (older than twice the read period), `refresh_error` (the last failure, or nil) and
        #   `version` (a count that moves when the state does)
        def latest
          return @source.call unless @background

          @lock.synchronize { with_age(@held || placeholder) }
        end

        private

        def refresh_forever
          loop do
            read_once
            after_read_once
            rest
          end
        end

        # Waits for the next read: the period, or less when woken. A loaded machine is read once
        # per `loaded_every` at most, woken or not.
        def rest
          began = monotonic
          @wake.pop(timeout: @every)
          left = @pace[:loaded_every] - (monotonic - began)
          @pace.fetch(:wait) { method(:sleep) }.call(left) if left.positive? && @guard&.loaded?
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Runs the after-read check; a check that raises, such as a restart that cannot exec, is
        # recorded and the loop goes on, so a failed check never freezes the board.
        def after_read_once
          @pace[:after_read]&.call
        rescue StandardError => e
          @lock.synchronize { @error = "#{e.class}: #{e.message.to_s.slice(0, 100)}" }
        end

        def read_once
          held = @source.call
          digest = Digest::SHA1.hexdigest(JSON.generate(held.except(:generated_at)))
          @lock.synchronize { record(held, digest) }
        rescue StandardError => e
          @lock.synchronize { @error = "#{e.class}: #{e.message.to_s.slice(0, 100)}" }
        end

        def record(held, digest)
          @version += 1 unless digest == @digest
          @digest = digest
          @held = held
          @error = nil
          @read_at = @now.call
        end

        def with_age(state)
          age = (@now.call - (@read_at || @started_at)).round
          state.merge(stale_seconds: age, stale: age > period * STALE_AFTER, refresh_error: @error, version: @version)
        end

        # The seconds between reads now: the loaded period while the guard says so.
        def period = @guard&.loaded? ? @pace[:loaded_every] : @every

        def placeholder
          { generated_at: @now.call.iso8601, stages: [], metrics: [], ci_runs: WAITING, slowest_jobs: WAITING,
            train_ci_runs: WAITING, train_slowest_jobs: WAITING, train_flakes: WAITING,
            open_work: WAITING, sessions: WAITING, events: WAITING, fanout: WAITING }
        end
      end
    end
  end
end
