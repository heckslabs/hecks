# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The board's one-line account of its sessions and the fill, computed from facts. Each count
      # is a `Session owner` word that {OwnerQueue} put on the session (`kind:`), so a number means
      # one thing; a session of another repository is in none of them.
      module Headline
        WAITING = ["waiting on a review verdict", "stranded run"].freeze
        FINISHED = "finished leftover"

        module_function

        # @param sessions [Array<Hash>] rows marked by {OwnerQueue.mark}
        # @param fill [Hash] the last fill report, or `{unknown:}`
        # @return [String] the sentence; a clause whose number is zero is left out
        def sentence(sessions, fill)
          counts = counts(sessions)
          clauses = [running(counts[:running], fill), *rest(counts)].compact
          "#{clauses.join(", ")}; #{load_note(fill)}; #{fill_note(fill)}"
        end

        # @return [Hash{Symbol => Integer}] running, waiting (on a verdict or the coordinator), you
        #   (the owner's queue) and finished (leftovers)
        def counts(sessions)
          kinds = sessions.is_a?(Array) ? sessions.filter_map { |row| row[:kind] } : []
          { running: kinds.count("running"), waiting: kinds.count { |kind| WAITING.include?(kind) },
            you: kinds.count("owner"), finished: kinds.count(FINISHED) }
        end

        def running(count, fill)
          cap = readable?(fill) && fill[:cap] ? " (cap #{fill[:cap]} items)" : ""
          "#{count.zero? ? "no" : count} #{count == 1 ? "session" : "sessions"} running#{cap}"
        end

        def rest(counts)
          [clause(counts[:waiting], "waiting on a review or the coordinator"), clause(counts[:you], "waiting on you"),
           clause(counts[:finished], "finished and waiting to be removed")]
        end

        def clause(count, words) = count.zero? ? nil : "#{count} #{words}"

        def load_note(fill)
          readable?(fill) && fill[:load] ? "load #{fill[:load]} of #{fill[:limit]}" : "load unknown"
        end

        # Whether the fill can start more, and when not, the reason its own report gives.
        def fill_note(fill)
          return "the fill can start more: unknown" unless readable?(fill)
          return "the fill can start more: yes" if Array(fill[:would_start]).any?

          "the fill can start more: no because #{refusal(fill)}"
        end

        def refusal(fill)
          return "load" if fill[:load] && fill[:limit] && fill[:load] >= fill[:limit]

          Array(fill[:skipped]).first&.fetch(:reason, nil) || "nothing planned"
        end

        def readable?(fill) = fill.is_a?(Hash) && !fill.key?(:unknown)
      end
    end
  end
end
