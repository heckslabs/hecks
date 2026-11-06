# frozen_string_literal: true

require "json"
require "time"
require_relative "console_capture"

module Hecks
  module Adapters
    # Wakes a Claude session in place with an answer, for `ClaudeAgents#resume`.
    #
    # The session is stopped when still listed as running, then `claude --bg --resume <full id> --
    # <answer>` runs with no `--agent` (the session keeps its saved options) and without the
    # calling session's `CLAUDE*` variables, so the CLI continues the same session under its own
    # id. Given flags, a short id, a live session or those variables, it starts a copy instead.
    class ClaudeResumption
      # The line the CLI prints when a resume started a copy instead of waking the session.
      COPY_NOTE = /^.*started a copy.*$/

      # The id of that copy.
      COPY_ID = /started a copy as\W*([0-9A-Za-z][0-9A-Za-z_-]{5,})/

      # Job states of a session that is not running.
      STOPPED_STATES = %w[stopped done failed].freeze

      # `CLAUDE*` variables that carry credentials or configuration, not the calling session.
      KEPT_VARIABLES = /\ACLAUDE_(CONFIG_DIR|CODE_OAUTH_TOKEN|CODE_USE_\w+)\z/

      # @param command [String] the program that resumes and stops sessions
      # @param shell [Shell] runs it
      # @param nice [Array<String>] the niceness prefix of the command line, if any
      def initialize(command, shell, nice: [])
        @command = command
        @shell = shell
        @nice = nice
      end

      # @param id [String] the id the run holds
      # @param entry [Hash] the session as `claude agents --json` lists it
      # @param answer [String] the prompt to wake it with
      # @param env [Hash] the session environment to keep (`CARGO_TARGET_DIR`)
      # @param chdir [String] the run's directory
      # @return [Hash{Symbol => Object}] `resumed_at:`, `session:` the id the run follows (its own
      #   unless the CLI started a copy) and, for a copy, `note:` what the CLI said
      # @raise [ConsoleCapture::Failure] when the session has no full id or the command refuses
      def call(id, entry, answer, env:, chdir:)
        full = entry["sessionId"].to_s
        raise ConsoleCapture::Failure, "session #{id} is listed with no full session id" if full.empty?

        stop(entry)
        result = @shell.capture(*@nice, @command, "--bg", "--resume", full, "--", answer,
                                env: cleared.merge(env), chdir: chdir)
        raise ConsoleCapture::Failure, "#{@command} resume #{id} refused: #{result.err.strip}" unless result.ok?

        outcome(id, result.out)
      end

      private

      def stop(entry)
        return if STOPPED_STATES.include?(entry["state"].to_s)

        @shell.capture(@command, "stop", entry.fetch("id", entry["sessionId"]).to_s)
      end

      # Each inherited `CLAUDE*` variable that names the calling session, unset.
      def cleared
        ENV.keys.select { |name| name.start_with?("CLAUDE") && !KEPT_VARIABLES.match?(name) }.to_h { |name| [name, nil] }
      end

      def outcome(id, out)
        at = { value: Time.now.utc.iso8601 }
        note = out[COPY_NOTE]
        return { resumed_at: at, session: { value: id } } unless note

        copy = out[COPY_ID, 1] || out[ClaudeAgents::SESSION_ID, 1] || id
        { resumed_at: at, session: { value: copy }, note: { value: note.strip } }
      end
    end
  end
end
