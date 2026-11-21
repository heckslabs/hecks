# frozen_string_literal: true

require "fileutils"
require "hecks/cache_dir"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Beating` port's adapter for `Heartbeat`: the one place a beat runs in. It takes a
    # kernel `flock` on one file under the cache directory and keeps it for the life of the beat's
    # process (a beat is a one-shot dispatch), so a killed holder frees it at once. A beat that
    # finds the place held by another process is refused, naming the holder's pid and age; the
    # bluebook records the refusal and runs no policy for it. A process that holds the place
    # takes it again without waiting, so its own later beats are not refused.
    class Beating
      # The file's name under the cache directory's `beat` folder.
      FILE = "beat.lock"
      # Seconds a beat may hold the place: the clock beats once a minute, so a beat that is still
      # running after this has stalled, and its process ends so the next beat can run.
      WINDOW = 300

      @held = nil

      class << self
        # @return [File, nil] the lock this process holds, if it holds one
        attr_accessor :held
      end

      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `dir:` stands in for the lock's directory, `clock:` for the seconds
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @dir = settings[:dir] || Hecks::CacheDir.path("beat")
        @clock = settings[:clock] || -> { Time.now.to_i }
        @window = settings[:window] || WINDOW
        @sleeper = settings[:sleeper] || method(:sleep)
        @ender = settings[:ender] || -> { Process.exit!(75) }
      end

      # The `Take` ask: holds the place for this process.
      #
      # @return [Hash] nothing to add to the answer
      # @raise [ConsoleCapture::Failure] "beat already running (pid, age)" while another
      #   process holds the place
      def take(**)
        return {} if self.class.held

        file = open_place
        raise ConsoleCapture::Failure, running(file) unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.truncate(0)
        file.write("#{Process.pid} #{@clock.call}")
        file.flush
        self.class.held = file
        arm_deadline
        {}
      end

      private

      # Ends this process once the window has passed, which frees the place at once; the thread is
      # the beat's own, so a beat that spins or waits still ends.
      def arm_deadline
        sleeper = @sleeper
        window = @window
        ender = @ender
        Thread.new do
          sleeper.call(window)
          ender.call
        end
      end

      def open_place
        FileUtils.mkdir_p(@dir)
        File.new(File.join(@dir, FILE), File::CREAT | File::RDWR, 0o600)
      end

      def running(file)
        pid, started = holder(file)
        "beat already running (pid #{pid}, age #{@clock.call - started} s)"
      ensure
        file.close
      end

      # @return [Array<Integer>] the pid and start time the holder wrote
      def holder(file) = (file.read.to_s.split.map(&:to_i) + [0, 0]).first(2)
    end
  end
end
