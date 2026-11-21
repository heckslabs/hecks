# frozen_string_literal: true

require "shellwords"
require_relative "session_inbox"
require_relative "claude_jobs"
require_relative "state_gate"

module Hecks
  module Adapters
    # The hooks a dispatched session carries in its settings. The end of a turn and the end of the
    # session reach Hecks as a check of its own run instead of waiting for a sweep: Claude Code runs
    # `Stop` after each turn (a session that finishes or blocks has just ended one) and `SessionEnd`
    # when the session is stopped. The job's state file can lag the hook by a moment, so the command
    # waits once, then checks only when the state changed since its last check (see {StateGate}):
    # a stop with nothing new boots nothing.
    #
    # `PostToolUse` and `Stop` also read the session's inbox (see {SessionInbox}), so an answer left
    # for a working session reaches it at its next tool call or the end of its turn.
    class SessionHooks
      # Seconds the command waits before it reads the job's state.
      SETTLE = 3

      # Where the last checked state of each run is kept unless a setting names another directory.
      SEEN = "~/.claude/hecks-dev/checked"

      # @param launcher [String, nil] the main checkout's `exe/hecks`, which owns the ledgers; nil
      #   for none
      # @param inbox [SessionInbox] where an answer for the session waits
      # @param jobs [String, nil] the jobs directory (default {ClaudeJobs::DIRECTORY})
      # @param seen [String, nil] where each run's last checked state is kept (default
      #   {SessionHooks::SEEN})
      # @param settle [Numeric] seconds the check waits before it reads the job's state
      def initialize(launcher:, inbox: SessionInbox.new, jobs: nil, seen: nil, settle: SETTLE)
        @launcher = launcher
        @inbox = inbox
        @gate = StateGate.new(jobs: File.expand_path(jobs || ClaudeJobs::DIRECTORY),
                              seen: File.expand_path(seen || SEEN), settle: settle)
      end

      # @param run [String] the key of the `AgentRun` the session belongs to
      # @return [Hash] the settings `hooks` block, empty when there is no launcher or no run
      def for(run)
        return {} if @launcher.to_s.empty? || run.to_s.empty?

        { "PostToolUse" => entry(@inbox.hook(run)), "Stop" => entry(@inbox.hook(run), turn_end(run), command(run)),
          "SessionEnd" => entry(command(run)) }
      end

      # The words the launcher's report carries when the Coder bluebook held the turn.
      HELD = 'failure state "held"'

      # The `Stop` command that asks the Coder bluebook whether the turn may end. Claude Code gives
      # the hook `stop_hook_active` on its input when this stop follows one a hook refused, which
      # goes to the bluebook as `again`. Only a turn the bluebook held prints its refusal on stderr
      # and exits 2, which Claude Code shows the model instead of ending the turn; any other
      # outcome, a launcher that failed included, exits 0.
      #
      # @param run [String] the key of the run the session belongs to
      # @return [String] the shell command
      def turn_end(run)
        ask = "#{Shellwords.escape(@launcher)} coder Turn.end! run.value=#{Shellwords.escape(run)} again.value=$a --wait"
        "a=false; grep -q '\"stop_hook_active\": *true' && a=true; out=$(#{ask} 2>&1 >/dev/null); " \
          "case \"$out\" in *#{Shellwords.escape(HELD)}*) " \
          "printf '%s\\n' \"$out\" | grep -F #{Shellwords.escape(HELD)} >&2; exit 2;; esac; exit 0"
      end

      private

      def entry(*commands) = [{ "hooks" => commands.map { |line| { "type" => "command", "command" => line } } }]

      def command(run)
        check = "#{Shellwords.escape(@launcher)} AgentRun.check! to=#{Shellwords.escape(run)} >/dev/null 2>&1"
        @gate.command(run, check)
      end
    end
  end
end
