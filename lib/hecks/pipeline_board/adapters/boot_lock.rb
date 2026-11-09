# frozen_string_literal: true

require "monitor"
require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # The one lock every boot or description of a domain in the board process goes through.
      #
      # `Hecks.describe`, `Hecks.boot` and `Hecks.with_registry` set a registry that the whole
      # process sees as current, not one per thread, so two of them at once can register one
      # domain's declarations in the other's registry. The board runs several: the live store's
      # boot on its own thread, the readers that describe a bluebook, and the wiring page's
      # reload. They take turns.
      #
      # A boot is long, so a thread that answers a request does not wait for it without end: it
      # gives up after {WAIT_SECONDS} and says a boot is still going, as the live store does for a
      # reader. The boot threads themselves wait their turn.
      module BootLock
        LOCK = Monitor.new
        # Seconds a request thread waits for a boot that holds the lock.
        WAIT_SECONDS = 30
        # Seconds between looks for the lock while waiting.
        POLL_SECONDS = 0.05

        module_function

        # Runs the block as the only boot or description in the process.
        #
        # @param wait [Numeric, nil] how long to wait for a boot that holds the lock; nil waits
        #   for ever, as a boot thread does
        # @param clock [#call] the time in seconds; a spec stands in
        # @yield the boot, description or registry-setting reload
        # @return [Object] the block's result
        # @raise [Unavailable] when another boot still holds the lock after `wait` seconds
        def exclusive(wait: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, &)
          return LOCK.synchronize(&) unless wait

          entered?(wait, clock) ? held(&) : raise(Unavailable, "a boot is still going in this process")
        end

        # @return [Boolean] whether the lock was taken within `wait` seconds
        def entered?(wait, clock)
          deadline = clock.call + wait
          until LOCK.mon_try_enter
            return false if clock.call >= deadline

            sleep(POLL_SECONDS)
          end
          true
        end

        # Runs the block with the lock taken by {entered?}, and gives it back.
        def held
          yield
        ensure
          LOCK.mon_exit
        end
      end
    end
  end
end
