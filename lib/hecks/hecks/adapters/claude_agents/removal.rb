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
      # It needs the including adapter's `@transcript`, `@reaping`, `@listing`, `@shell` and
      # `@command`.
      module Removal
        # What `claude rm` prints when it keeps a session because its worktree still stands, and the
        # part of it that says where.
        WORKTREE_KEPT = /kept .*its worktree is still at/
        WORKTREE_AT = /its worktree is still at.*/

        # Says whether a person replied in a session after its brief, and what else decides whether
        # the session may go: whether the run's Work is open, whether the run leaves a product,
        # and what its worktree holds.
        #
        # A session the listing does not hold was removed elsewhere, and is answered as gone.
        #
        # @param held [Hash] the `AgentRun` record: `session`
        # @return [Hash{Symbol => Object}] `listed:` whether `claude agents` lists the session; for
        #   a listed one `taken_over:` true when a person replied or the transcript cannot be read,
        #   `note:` which of those it was in words, and {SessionReaping#facts}; for a gone one
        #   `gone_at:`, when it was found gone, as an ISO 8601 string
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def review(**held)
          entry = @listing.find(plain(held[:session]).to_s)
          return gone unless entry

          full = entry["sessionId"]
          reading = @transcript.reading(full)
          { listed: true, taken_over: reading[:state] != :read || reading[:person_turns].positive?,
            note: reply_note(reading), **@reaping.facts(held, worktree_of(full)) }
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
          removed?(id) || kept_or_stopped(id)
          { removed_at: { value: Time.now.utc.iso8601 } }
        end

        private

        def gone = { listed: false, note: "the session is not listed", gone_at: { value: Time.now.utc.iso8601 } }

        # Says what the transcript showed: a person's turns, a missing or unreadable transcript, or
        # nobody.
        def reply_note(reading)
          case reading[:state]
          when :missing then "the transcript is missing"
          when :unreadable then "the transcript cannot be read"
          else
            turns = reading[:person_turns]
            turns.positive? ? "a person replied (#{turns} turns after the brief)" : "nobody replied"
          end
        end

        # `claude rm` keeps a session whose worktree still stands; stopping it would not help.
        def kept_or_stopped(id)
          return stopped(id) unless @refusal.match?(WORKTREE_KEPT)

          raise ConsoleCapture::Failure, "session kept: #{@refusal[WORKTREE_AT]}"
        end

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
