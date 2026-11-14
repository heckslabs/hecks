# frozen_string_literal: true

require "etc"
require "json"
require "time"
require "tmpdir"
require_relative "load_guard"

module Hecks
  module Adapters
    module PipelineBoard
      # The machine's load over the last hours, for the board's load chart. A serving board samples
      # the 1-minute load average every few seconds on a thread of its own, through
      # {LoadGuard.reading}, which starts no program, so the chart never adds to what it draws.
      #
      # The board restarts itself whenever its code moves, so the samples are also kept in one
      # small file in the temporary directory and read back when a board starts: the chart shows
      # the hours before the restart, with a gap for the seconds the board was away.
      class LoadHistory
        # Seconds between samples.
        EVERY = 10
        # The samples kept: three hours of them.
        KEPT = 1080
        # Where a serving board keeps its samples between restarts.
        PATH = File.join(Dir.tmpdir, "hecks-pipeline-board-load.json")

        class << self
          # The history a serving board keeps; nil until one stands.
          # @return [LoadHistory, nil]
          attr_accessor :shared

          # Starts this process's history, once, from the samples the last board left.
          #
          # @param limit [Numeric] the load above which the machine counts as loaded
          # @return [LoadHistory]
          def stand(limit) = self.shared ||= new(limit: limit, path: PATH).tap(&:start)

          # @return [Hash, nil] the standing history's {#reading}; nil when none stands
          def reading = shared&.reading
        end

        # @param limit [Numeric] the load above which the machine counts as loaded
        # @param load [#call] answers the 1-minute load average
        # @param now [#call] answers the current time
        # @param every [Numeric] seconds between samples
        # @param path [String, nil] the file the samples are kept in; none keeps them in memory only
        def initialize(limit:, load: LoadGuard.method(:reading), now: -> { Time.now.utc }, every: EVERY, path: nil)
          @limit = limit
          @load = load
          @now = now
          @every = every
          @path = path
          @lock = Mutex.new
          @samples = kept_before
        end

        # Samples on a thread until the process ends. A sample that raises is skipped.
        #
        # @return [Thread]
        def start
          Thread.new { sample_forever }.tap { |thread| thread.report_on_exception = false }
        end

        # Records the load now, forgets the samples older than the ones kept, and keeps the rest
        # for the next board.
        #
        # @return [void]
        def sample
          taken = [@now.call.iso8601, @load.call.to_f.round(2)]
          held = @lock.synchronize do
            @samples << taken
            @samples.shift while @samples.size > KEPT
            @samples.dup
          end
          keep(held)
        end

        # @return [Hash] `samples` (oldest first, each a time and a load), `limit`, `cores` (the
        #   processors the load is spread over) and `every` (seconds between samples)
        def reading
          { samples: @lock.synchronize { @samples.dup }, limit: @limit.to_f.round(1), cores: Etc.nprocessors, every: @every }
        end

        private

        # The samples an earlier board left that are still inside the time kept; none when there is
        # no file, or it cannot be read.
        def kept_before
          return [] unless @path && File.readable?(@path)

          oldest = (@now.call - (KEPT * @every)).iso8601
          held = JSON.parse(File.read(@path))
          held.select { |time, load| time.is_a?(String) && load.is_a?(Numeric) && time >= oldest }.last(KEPT)
        rescue JSON::ParserError, SystemCallError
          []
        end

        # Written beside the file and moved into place, so a board never reads half of it.
        def keep(samples)
          return unless @path

          File.write("#{@path}.part", JSON.generate(samples))
          File.rename("#{@path}.part", @path)
        rescue SystemCallError
          nil
        end

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
