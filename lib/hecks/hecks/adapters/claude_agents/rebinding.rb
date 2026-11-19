# frozen_string_literal: true

require_relative "../session_binding"

module Hecks
  module Adapters
    class ClaudeAgents
      # The asks of the `Agents` port that keep a pinned role on one live session: the stop of the
      # session a fork superseded, the look at a session a run is rebound to, and the sweep's
      # count of each pinned role's live sessions. Each reports facts; the bluebook judges them.
      #
      # It needs the including adapter's `@listing`, `@holder` and {Removal#stop_session}.
      module Rebinding
        # Stops the session the run held before an answer's resume started a copy.
        #
        # @param held [Hash] the `AgentRun` record: `forked_from`
        # @return [Hash] nothing: the stop is the answer
        # @raise [ConsoleCapture::Failure] with what the command said, when it refuses
        def stop_forked_from(**held) = stop_session(session: held[:forked_from])

        # @param held [Hash] the `AgentRun` record: `run`, `session`, and `target` the named session
        # @return [Hash{Symbol => Object}] the {SessionBinding} facts
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def inspect_session(**held) = SessionBinding.new(listing: @listing, runs: -> { @holder.runs }).call(held)

        # @param _held [Hash] the `SessionSweep` record, unused
        # @return [Hash{Symbol => Object}] the {WorkHolder#census}
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def check_roles(**_held) = @holder.census
      end
    end
  end
end
