# frozen_string_literal: true

module Hecks
  module Adapters
    class RecipientCheck
      # Whether a message's claimed sender is the run its sending session is registered as: an
      # AgentRun that is started, or a hand run, holding that session. The claimed name is the
      # sender's own word; the session is the shell's `$CLAUDE_CODE_SESSION_ID`, which it cannot
      # choose by what it writes in the message.
      class SenderProof
        # @param runs [#call] answers each run's key with its `session:`
        # @param hand_runs [HandRuns] the sessions registered by hand
        # @param session [#call, nil] answers the sending session id; the environment's when nil
        def initialize(runs:, hand_runs:, session: nil)
          @runs = runs
          @hand_runs = hand_runs
          @session = session || -> { ENV.fetch("CLAUDE_CODE_SESSION_ID", "") }
        end

        # @param name [String] the sender as the message names it
        # @return [Boolean] true when the sending session is the one registered under that name
        def verified?(name)
          sending = @session.call.to_s
          return false if sending.empty?

          [run_session(name), @hand_runs.session(name)].any? { |held| same?(held.to_s, sending) }
        end

        private

        def run_session(name) = (@runs.call.fetch(name, nil) || {})[:session]

        def same?(held, sending) = !held.empty? && (held.start_with?(sending) || sending.start_with?(held))
      end
    end
  end
end
