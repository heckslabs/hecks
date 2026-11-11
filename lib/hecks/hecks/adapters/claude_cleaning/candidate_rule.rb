# frozen_string_literal: true

module Hecks
  module Adapters
    class ClaudeCleaning
      # The rule that makes a listed session a candidate for removal: the AgentRun ledger holds a
      # dispatched run for it, that run is `finished` with condition `done`, the listing says `done`
      # and no person spoke in it. Anything else is kept, whatever `claude agents` lists, so the
      # owner's sessions, a blocked one, one a person stopped and the pruner's own (its run is still
      # `started` while it works) are never candidates.
      class CandidateRule
        # The run status and condition that make a run's session a candidate.
        ENDED = { status: "finished", condition: "done" }.freeze

        # @param runs [Hash{String => Hash}] each run's key with its `status:` and `condition:`
        # @param transcript [ClaudeTranscript] says whether a person spoke in a session
        def initialize(runs:, transcript:)
          @runs = runs
          @transcript = transcript
        end

        # @param entry [Hash] one session of the `claude agents` listing
        # @param key [String, nil] the key of the run the ledger binds to the session
        # @return [String, nil] why the session is not a candidate, or nil when it is
        def why_not(entry, key)
          return "no dispatched run holds it" unless key

          run = @runs.fetch(key, {})
          return "its run #{key} is #{ended(run)}, not finished done" unless run.slice(:status, :condition) == ENDED
          return "listed #{entry["state"]}, not done" unless ended?(entry)

          spoken(entry)
        end

        # A session has ended when the listing says `done`, or says `working` while its turn is over
        # (status `idle`): a coder that finished its Work and waits on nobody. A `busy` or `blocked`
        # session has not ended.
        #
        # @param entry [Hash] one session of the `claude agents` listing
        # @return [Boolean]
        def ended?(entry)
          state = entry["state"].to_s
          state == "done" || (state == "working" && entry["status"].to_s == "idle")
        end

        # @param entry [Hash] one session of the `claude agents` listing
        # @return [String, nil] "a person spoke in it" when its transcript says so or cannot be read
        def spoken(entry)
          @transcript.taken_over?(entry["sessionId"].to_s) ? "a person spoke in it" : nil
        end

        private

        def ended(run)
          words = [run[:status], run[:condition]].map(&:to_s).reject(&:empty?)
          words.empty? ? "unknown" : words.join(" ")
        end
      end
    end
  end
end
