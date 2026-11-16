# frozen_string_literal: true

require_relative "log_backoff"

module Hecks
  module Adapters
    module PipelineBoard
      # How {TrainFlakes} spends `gh` on the attempts it has not kept. An attempt whose read failed,
      # timed out or was cut off by the gather deadline is held for a back-off (see {LogBackoff})
      # and is not asked again until it ends, and one answer starts at most {ATTEMPT_READS} cold
      # reads, newest run first, so a board that starts cold warms over several refreshes and
      # never spends a whole refresh, or the machine, on the history.
      module AttemptReads
        # The most attempts one answer reads from GitHub; a kept or held attempt costs none.
        ATTEMPT_READS = 4

        private

        # Starts a new answer with a full allowance of cold reads.
        def allow_cold_reads! = @cold_left = ATTEMPT_READS

        # @return [Array<Hash>] the attempt's failed items, read from GitHub
        # @raise [PipelineBoard::Unavailable] when the attempt is held, the allowance is spent, or
        #   the read fails; no child is started for the first two
        def cold_attempt(key)
          raise PipelineBoard::Unavailable, "attempt #{key.last} of run #{key.first} failed lately" if @backoff.held?(key)
          raise PipelineBoard::Unavailable, "cold reads for this refresh are spent" if (@cold_left -= 1).negative?

          noted_read(key)
        end

        # Reads the attempt and clears its hold; any way out but an answer (an error, a timeout or
        # the thread being killed at the deadline) holds it, in the short back-off lock only.
        def noted_read(key)
          answered = false
          items = failed_items(*key)
          answered = true
          @backoff.clear!(key)
          items
        ensure
          @backoff.failed!(key) unless answered
        end
      end
    end
  end
end
