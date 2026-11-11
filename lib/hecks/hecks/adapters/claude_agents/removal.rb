# frozen_string_literal: true

require "json"
require "time"
require_relative "../console_capture"

module Hecks
  module Adapters
    class ClaudeAgents
      # The `Review`, `ClearScratch`, `RetireWorktree` and `Remove` asks of the `Agents` port: the
      # facts a finished run's session is judged on, and the three steps that take it away, each
      # a plain action the `AgentRun` bluebook asks for in its own order.
      #
      # It needs the including adapter's `@transcript`, `@reaping`, `@shell` and `@command`.
      module Removal
        # Says whether a person replied in a session after its brief, and what else decides whether
        # the session may go: whether the run's Work is open, whether the run leaves a product,
        # and what its worktree holds.
        #
        # @param held [Hash] the `AgentRun` record: `session`
        # @return [Hash{Symbol => Object}] `taken_over:` true when a person replied or the
        #   transcript cannot be read, `note:` that in words, and {SessionReaping#facts}
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed or this one is not
        #   among them
        def review(**held)
          full = listed(plain(held[:session]))["sessionId"]
          taken = @transcript.taken_over?(full)
          { taken_over: taken, note: taken ? "a person replied, or the transcript cannot be read" : "nobody replied",
            **@reaping.facts(held, worktree_of(full)) }
        end

        # Clears the scratch the world lists in the run's worktree.
        #
        # @param held [Hash] the `AgentRun` record: `session`
        # @return [Hash{Symbol => String}] `note:` what was cleared
        # @raise [ConsoleCapture::Failure] when the session is not listed
        def clear_scratch(**held) = @reaping.clear(worktree_of(listed(plain(held[:session]))["sessionId"]))

        # Retires the run's worktree and its branch, once the branch is on `main`.
        #
        # @param held [Hash] the `AgentRun` record: `session`
        # @return [Hash{Symbol => String}] `note:` what the retirement reported
        # @raise [ConsoleCapture::Failure] when the worktree holds anything that would be lost
        def retire_worktree(**held) = @reaping.retire(worktree_of(listed(plain(held[:session]))["sessionId"]))

        # Removes a session with `claude rm`; a session `claude rm` refuses (one that reads
        # blocked) is stopped with `claude stop`, never killed by pid, and removed again.
        #
        # @param held [Hash] the `AgentRun` record: `session`
        # @return [Hash{Symbol => Object}] `removed_at:` when it was removed, as an ISO 8601 string
        # @raise [ConsoleCapture::Failure] when the command refuses
        def remove(**held)
          id = plain(held[:session])
          removed?(id) || stopped(id)
          { removed_at: { value: Time.now.utc.iso8601 } }
        end

        private

        def worktree_of(full)
          path = @transcript.worktree(full)
          path.to_s
        rescue SystemCallError, JSON::ParserError
          ""
        end

        def removed?(id)
          result = @shell.capture(@command, "rm", id)
          @refusal = result.err.strip
          result.ok?
        end

        def stopped(id)
          @shell.capture(@command, "stop", id)
          return if removed?(id)

          raise ConsoleCapture::Failure, "#{@command} rm #{id} refused: #{@refusal}"
        end
      end
    end
  end
end
