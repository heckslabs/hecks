# frozen_string_literal: true

require "fileutils"
require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # The turn a verification of a checkout takes at its clean copy: one verification at a time
      # holds it, so the copy at its fixed path and the Cargo targets its crates link to are never
      # written by two. A verification that cannot take its turn within the wait is refused,
      # naming who holds it and since when, so it never waits without a word.
      module CopyLock
        # Seconds between two tries to take the lock.
        POLL = 5

        module_function

        # @param path [String] the lock file
        # @param wait [Numeric] the most seconds to wait for the turn
        # @return [Object] what the block answered
        # @raise [ConsoleCapture::Failure] when another verification holds the turn past the wait
        def hold(path, wait:)
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
            take(file, wait)
            note(file)
            yield
          end
        end

        # @return [void]
        # @raise [ConsoleCapture::Failure] when the turn is not free within `wait`
        def take(file, wait)
          deadline = clock + wait
          until file.flock(File::LOCK_EX | File::LOCK_NB)
            raise ConsoleCapture::Failure, busy(file, wait) if clock >= deadline

            sleep POLL
          end
        end

        # @return [String] the refusal: who holds the turn, and how long this one waited
        def busy(file, wait)
          holder = File.read(file.path).strip
          "another verification holds #{file.path} (#{holder.empty? ? "unnamed" : holder}); waited #{wait} seconds"
        end

        # Writes the holder's process and start time into the lock file, for a refusal to name.
        #
        # @return [void]
        def note(file)
          file.truncate(0)
          file.write("pid #{Process.pid} since #{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}")
          file.flush
        end

        # @return [Float] a monotonic clock in seconds
        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
