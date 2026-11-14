# frozen_string_literal: true

require "etc"
require "time"
require_relative "load_guard"

module Hecks
  module Adapters
    module PipelineBoard
      # The machine's load over the last minutes, for the board's load chart. A serving board
      # samples the 1-minute load average every few seconds on a thread of its own, through
      # {LoadGuard.reading}, which starts no program, so the chart never adds to what it draws.
      # The samples live in this process only: a board that restarts starts its chart again.
      class LoadHistory
        # Seconds between samples.
        EVERY = 5
        # The samples kept: fifteen minutes of them.
        KEPT = 180

        class << self
          # The history a serving board keeps; nil until one stands.
          # @return [LoadHistory, nil]
          attr_accessor :shared

          # Starts this process's history, once.
          #
          # @param limit [Numeric] the load above which the machine counts as loaded
          # @return [LoadHistory]
          def stand(limit) = self.shared ||= new(limit: limit).tap(&:start)

          # @return [Hash, nil] the standing history's {#reading}; nil when none stands
          def reading = shared&.reading
        end

        # @param limit [Numeric] the load above which the machine counts as loaded
        # @param load [#call] answers the 1-minute load average
        # @param now [#call] answers the current time
        # @param every [Numeric] seconds between samples
        def initialize(limit:, load: LoadGuard.method(:reading), now: -> { Time.now.utc }, every: EVERY)
          @limit = limit
          @load = load
          @now = now
          @every = every
          @lock = Mutex.new
          @samples = []
        end

        # Samples on a thread until the process ends. A sample that raises is skipped.
        #
        # @return [Thread]
        def start
          Thread.new { sample_forever }.tap { |thread| thread.report_on_exception = false }
        end

        # Records the load now, and forgets the samples older than the ones kept.
        #
        # @return [void]
        def sample
          taken = [@now.call.iso8601, @load.call.to_f.round(2)]
          @lock.synchronize do
            @samples << taken
            @samples.shift while @samples.size > KEPT
          end
        end

        # @return [Hash] `samples` (oldest first, each a time and a load), `limit`, `cores` (the
        #   processors the load is spread over) and `every` (seconds between samples)
        def reading
          { samples: @lock.synchronize { @samples.dup }, limit: @limit.to_f.round(1), cores: Etc.nprocessors, every: @every }
        end

        private

        def sample_forever
          loop do
            begin
              sample
            rescue StandardError
              nil
            end
            sleep @every
          end
        end
      end
    end
  end
end
