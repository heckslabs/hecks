# frozen_string_literal: true

require_relative "console_capture"

module Hecks
  module Adapters
    # The `Weighing` port's adapter for `CatcherCare`: on a beat, measures how long the Catcher's
    # SQLite file (and its write-ahead log) has stood untouched and says the Catcher is due once the
    # Tickets world's `catcher_care` minutes have passed. A file touched inside the window is
    # deferred by name; a Catcher that has never written its file is due. It reads file times only.
    class CatcherWeighing
      # The Tickets world verb that carries the window.
      VERB = "catcher_care"

      # Minutes the Catcher's file stands untouched before a beat runs it, if the world names none.
      MINUTES = 30

      # Where the Catcher keeps its records, when the settings name no file.
      DEFAULT_PATH = File.expand_path("~/.claude/hecks-dev/catcher.db")

      # @param registry [Runtime::Registry, nil] the booted registry whose world names the window
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the Catcher's file, `now:` a stand-in clock (a Time)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @path = settings[:path] || DEFAULT_PATH
        @now = settings[:now]
      end

      # @param _held [Hash] the `CatcherCare` record: `run`; unused
      # @return [Hash{Symbol => Hash}] `reason`, why the Catcher is due
      # @raise [ConsoleCapture::Failure] naming why the Catcher is left for the next beat
      def rested(**_held)
        idle = idle_minutes
        raise ConsoleCapture::Failure, inside(idle) if idle && idle < minutes

        { reason: { value: due(idle) } }
      end

      private

      def due(idle) = idle ? "the Catcher's file has stood #{idle.floor} minutes, past #{minutes}" : "the Catcher has not run"

      def inside(idle) = "deferred: the Catcher's file was touched #{idle.floor} minutes ago, inside #{minutes}"

      def minutes
        declared = @registry&.world("Tickets")&.for_verb(VERB) || {}
        declared[:minutes] || MINUTES
      end

      def idle_minutes
        touched = [@path, "#{@path}-wal"].select { |file| File.file?(file) }.map { |file| File.mtime(file) }.max
        touched && (((@now || Time.now) - touched) / 60.0)
      end
    end
  end
end
