# frozen_string_literal: true

require "shellwords"

module Hecks
  module Adapters
    # The hooks a dispatched session carries in its settings, so the end of a turn and the end of
    # the session reach Hecks as a check of its own run instead of waiting for a sweep. Claude Code
    # runs `Stop` after each turn (a session that finishes or blocks has just ended one) and
    # `SessionEnd` when the session is stopped. The job's state file can lag the hook by a moment,
    # so the command checks, waits, and checks again: a check that finds nothing new records
    # nothing.
    class SessionHooks
      # Seconds the command waits before its second check.
      SETTLE = 3
      # The events a session announces itself on.
      EVENTS = %w[Stop SessionEnd].freeze

      # @param launcher [String, nil] the main checkout's `exe/hecks`, which owns the ledgers; nil
      #   for none
      def initialize(launcher:)
        @launcher = launcher
      end

      # @param run [String] the key of the `AgentRun` the session belongs to
      # @return [Hash] the settings `hooks` block, empty when there is no launcher or no run
      def for(run)
        return {} if @launcher.to_s.empty? || run.to_s.empty?

        EVENTS.to_h { |event| [event, [{ "hooks" => [{ "type" => "command", "command" => command(run) }] }]] }
      end

      private

      def command(run)
        check = "#{Shellwords.escape(@launcher)} AgentRun.check! to=#{Shellwords.escape(run)} >/dev/null 2>&1"
        "#{check}; sleep #{SETTLE}; #{check}; exit 0"
      end
    end
  end
end
