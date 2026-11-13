# frozen_string_literal: true

require "shellwords"
require_relative "session_inbox"

module Hecks
  module Adapters
    # The hooks a dispatched session carries in its settings. The end of a turn and the end of the
    # session reach Hecks as a check of its own run instead of waiting for a sweep: Claude Code runs
    # `Stop` after each turn (a session that finishes or blocks has just ended one) and `SessionEnd`
    # when the session is stopped. The job's state file can lag the hook by a moment, so the command
    # checks, waits, and checks again: a check that finds nothing new records nothing.
    #
    # `PostToolUse` and `Stop` also read the session's inbox (see {SessionInbox}), so an answer left
    # for a working session reaches it at its next tool call or the end of its turn.
    class SessionHooks
      # Seconds the command waits before its second check.
      SETTLE = 3

      # @param launcher [String, nil] the main checkout's `exe/hecks`, which owns the ledgers; nil
      #   for none
      # @param inbox [SessionInbox] where an answer for the session waits
      def initialize(launcher:, inbox: SessionInbox.new)
        @launcher = launcher
        @inbox = inbox
      end

      # @param run [String] the key of the `AgentRun` the session belongs to
      # @return [Hash] the settings `hooks` block, empty when there is no launcher or no run
      def for(run)
        return {} if @launcher.to_s.empty? || run.to_s.empty?

        { "PostToolUse" => entry(@inbox.hook(run)), "Stop" => entry(@inbox.hook(run), command(run)),
          "SessionEnd" => entry(command(run)) }
      end

      private

      def entry(*commands) = [{ "hooks" => commands.map { |line| { "type" => "command", "command" => line } } }]

      def command(run)
        check = "#{Shellwords.escape(@launcher)} AgentRun.check! to=#{Shellwords.escape(run)} >/dev/null 2>&1"
        "#{check}; sleep #{SETTLE}; #{check}; exit 0"
      end
    end
  end
end
