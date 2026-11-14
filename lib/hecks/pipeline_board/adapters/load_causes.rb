# frozen_string_literal: true

require "time"
require_relative "load_history"
require_relative "../../hecks/adapters/machine_sampling"

module Hecks
  module Adapters
    module PipelineBoard
      # What is using the CPU, for the board's load chart: the process classes the `Machine`
      # aggregate's `Busiest` query answers, read every half minute on a thread of its own. It is
      # the one program the board runs while the machine is loaded (`ps`, once a read), because a
      # loaded machine is when the answer is wanted; it changes nothing.
      class LoadCauses
        # Seconds between reads.
        EVERY = 30
        # The classes shown, busiest first.
        SHOWN = 6

        class << self
          # The reader a serving board keeps; nil until one stands.
          # @return [LoadCauses, nil]
          attr_accessor :shared

          # Starts this process's reader, once.
          # @return [LoadCauses]
          def stand = self.shared ||= new.tap(&:start)

          # @return [Hash, nil] the standing reader's {#reading}; nil when none stands
          def reading = shared&.reading

          # @return [Hash] what the board's state carries about the load: `load_history` (see
          #   {LoadHistory#reading}) and `load_causes`, each nil when no board stands one
          def with_history = { load_history: LoadHistory.reading, load_causes: reading }
        end

        # @param rows [#call] answers the process classes, busiest first: `name`, `count`, `cpu`
        #   and `session` each
        # @param now [#call] answers the current time
        # @param every [Numeric] seconds between reads
        def initialize(rows: -> { MachineSampling::ProcessClasses.new.rows }, now: -> { Time.now.utc }, every: EVERY)
          @rows = rows
          @now = now
          @every = every
          @lock = Mutex.new
          @held = { at: nil, classes: [] }
        end

        # Reads on a thread until the process ends. A read that raises keeps the last answer.
        #
        # @return [Thread]
        def start
          Thread.new { read_forever }.tap { |thread| thread.report_on_exception = false }
        end

        # Reads the busiest classes now.
        #
        # @return [void]
        def read
          classes = @rows.call.first(SHOWN).map { |row| row.to_h.transform_keys(&:to_sym).slice(:name, :count, :cpu, :session) }
          @lock.synchronize { @held = { at: @now.call.iso8601, classes: classes } }
        end

        # @return [Hash] `at` (when it was read, nil before the first) and `classes` (busiest first)
        def reading = @lock.synchronize { @held.dup }

        private

        def read_forever
          loop do
            begin
              read
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
