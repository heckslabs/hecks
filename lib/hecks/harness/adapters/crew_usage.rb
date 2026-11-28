# frozen_string_literal: true

require "time"
require_relative "crew_usage/calc"
require_relative "crew_usage/transcripts"
require_relative "crew_usage/finished"
require_relative "crew_usage/text"

module Hecks
  module Adapters
    # The `CrewUsage` port's adapter for `Harness::Baseline`: the crew's tokens per minute, cache
    # hit rate by role and items finished per hour over one sixty-minute window of a sprint day.
    # The tokens come from the session transcripts and the finished items from the event tap; it
    # reads both and never writes. The window's length and the formulas are `Calc`'s.
    class CrewUsage
      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `projects:` the transcripts directory, `tap:` a log path
      def initialize(registry: nil, aggregate: nil, settings: {})
        @projects = settings[:projects] || File.join(Dir.home, ".claude", "projects")
        @tap = settings[:tap]
      end

      # @param held [Hash] the query's `day`, an ISO date, and `start`, an ISO time (the day's first
      #   moment when absent)
      # @return [Hash{Symbol => String}] `text:` the reading
      def reading(**held)
        day = plain(held[:day])
        start = Time.iso8601(plain(held[:start]) || "#{day}T00:00:00Z")
        window = start...(start + (Calc::WINDOW_MINUTES * 60))
        transcripts = Transcripts.new(@projects, window)
        calc = Calc.new(transcripts.calls, finished: Finished.new(@tap).count(window))
        { text: Text.new(day, start, calc, transcripts).to_s }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
