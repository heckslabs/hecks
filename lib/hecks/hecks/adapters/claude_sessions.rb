# frozen_string_literal: true

require "time"
require_relative "shell"
require_relative "console_capture"
require_relative "claude_session_listing"
require_relative "dispatching/work_items"
require_relative "../../pipeline_board/adapters/pipeline_stages/agent_roles"

module Hecks
  module Adapters
    # The `Sessions` port's adapter for `PlainSession`: removes a session the board started by hand
    # with `claude rm`, retires a stray one, and reports the facts a retirement is judged on.
    #
    # It decides nothing. Whether a session is finished and waits on nobody, and whether a session
    # may be retired, are the bluebook's rules; this only looks and runs the removal. The command is
    # an argument list, never a string for a shell.
    class ClaudeSessions
      # The command that removes sessions.
      COMMAND = "claude"

      # Why a retired session was retired.
      REASON = "bound to no live run"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `command:` the program (default `claude`)
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] whose agent runs say which session is a run's
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @command = settings[:command] || COMMAND
        @shell = Shell.new
        @listing = ClaudeSessionListing.new(@command, shell: @shell)
        @runs = Dispatching::WorkItems.new(registry)
        @roles = pinned_roles(registry)
      end

      # Removes one session with `claude rm`.
      #
      # @param session [Hash, String] the session's id
      # @return [Hash{Symbol => Hash}] `removed_at:` when it was removed, as an ISO 8601 string
      # @raise [ConsoleCapture::Failure] when the command refuses
      def discard(session:)
        id = plain(session)
        result = @shell.capture(@command, "rm", id)
        raise ConsoleCapture::Failure, "#{@command} rm #{id} refused: #{result.err.strip}" unless result.ok?

        { removed_at: { value: Time.now.utc.iso8601 } }
      end

      # Reads the facts a retirement is judged on, and changes nothing.
      #
      # @param session [Hash, String] the session's id
      # @return [Hash{Symbol => Object}] `run:` the key of the run that holds it (empty when none),
      #   `bound:` whether that run is still started, `pinned:` whether its name begins with a
      #   pinned role, `working:` whether its job is working, and `note:` that in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed or it is not listed
      def examine(session:)
        id = plain(session)
        entry = @listing.find(id) || raise(ConsoleCapture::Failure, "no session #{id} is listed")
        key = run_key(entry)
        facts(entry, key, !key.empty? && @runs.runs.dig(key, :status) == "started")
      end

      # Retires a session: `claude rm`, then `claude stop` and `claude rm` again only when it is
      # still listed after the first removal.
      #
      # @param session [Hash, String] the session's id
      # @return [Hash{Symbol => Hash}] `session:`, `reason:` (the session is bound to no live run)
      #   and `retired_at:` (ISO 8601)
      # @raise [ConsoleCapture::Failure] when the session is still listed after both
      def withdraw(session:)
        id = plain(session)
        gone?(id) || stopped(id)
        { session: { value: id }, reason: { value: REASON }, retired_at: { value: Time.now.utc.iso8601 } }
      end

      private

      # The roles the Agents bluebook's `PinnedRole` rows name; every declared role when the
      # bluebook is not loaded, so a missing row refuses more and never retires a pinned session.
      def pinned_roles(registry)
        @runs.pinned_roles || PipelineBoard::AgentRoles.declared(registry)
      end

      def run_key(entry)
        held = @runs.run_sessions.values_at(entry["id"], entry["sessionId"])
        held.compact.first.to_s
      end

      def facts(entry, key, bound)
        pinned = @roles.any? { |role| entry["name"].to_s.start_with?(role) }
        holds = key.empty? ? "holds no run" : "holds run #{key}"
        { run: key, bound: bound, pinned: pinned, working: entry["state"].to_s == "working",
          note: "session #{entry["id"]} #{holds}, #{entry["state"]}" }
      end

      def gone?(id)
        @shell.capture(@command, "rm", id)
        @listing.find(id).nil?
      end

      def stopped(id)
        @shell.capture(@command, "stop", id)
        return true if gone?(id)

        raise ConsoleCapture::Failure, "#{@command} rm #{id} refused: the session is still listed"
      end

      def plain(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s)["value"].to_s : value.to_s
    end
  end
end
