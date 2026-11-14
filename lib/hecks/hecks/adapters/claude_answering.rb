# frozen_string_literal: true

require_relative "claude_resumption"
require_relative "session_hooks"
require_relative "session_inbox"
require_relative "session_presence"

module Hecks
  module Adapters
    # The answering side of the `Agents` port, part of {ClaudeAgents}: where a session is, the
    # delivery of an answer to a working one, and the resume of an idle or gone one. Which of them
    # an answer takes is the bluebook's `AnswerTheSessionWhereItIs` rule.
    module ClaudeAnswering
      # Says where the run's session is before it is answered (see {SessionPresence}).
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `listed:`, `status:`, `state:` and `note:`
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def present(**held) = @presence.call(plain(held[:session]))

      # Leaves the answer in a working session's inbox, which its hooks hand to the model; the
      # session is not stopped.
      #
      # @param held [Hash] the `AgentRun` record: `run`, `session` and `answer`, and `step` when
      #   the answer comes with the session's next step (it leads the answer)
      # @return [Hash{Symbol => Object}] `queued_at:` and `session:`
      # @raise [ConsoleCapture::Failure] when the session carries no inbox hook
      def deliver(**held) = @presence.deliver(plain(held[:run]), plain(held[:session]), prompt(held))

      # Answers an idle or gone session by waking it in place under its own id (see
      # {ClaudeResumption}), which takes the listing's full session id, not the short one the run
      # holds. It answers once the woken session's job reads a state other than `stopped`
      # ({ClaudeJobs#woken}).
      #
      # @param held [Hash] the `AgentRun` record: `session`, `repo` and `answer`, `step` when the
      #   answer comes with the session's next step (it leads the prompt), and `agent` when the run
      #   has a role, which the resume passes as `--agent` so its MCP server narrows itself again
      # @return [Hash{Symbol => Object}] `resumed_at:` an ISO 8601 string; `session:` the id the
      #   run follows, its own unless the CLI started a copy; and `note:` what the CLI said of that
      #   copy, when it did
      # @raise [ConsoleCapture::Failure] when the session is not listed or the command refuses
      def resume(**held)
        id = plain(held[:session])
        @jobs.woken(ClaudeResumption.new(@command, @shell, nice: niceness)
                                    .call(id, listed(id), prompt(held), env: named(held), chdir: plain(held[:repo]),
                                                                        agent: plain(held[:agent])))
      end

      private

      # The session hooks and the presence look, over one inbox (`inbox:` names its directory).
      def session_hooks(settings)
        inbox = SessionInbox.new(directory: settings[:inbox])
        @presence = SessionPresence.new(listing: @listing, jobs: @jobs, inbox: inbox)
        SessionHooks.new(launcher: settings.fetch(:launcher) { MainLauncher.path }, inbox: inbox)
      end
    end
  end
end
