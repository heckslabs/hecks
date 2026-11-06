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

      # Seconds a stopped session is given to read as stopped before the resume goes ahead.
      STOP_PATIENCE = 10

      # `CLAUDE*` variables that carry credentials or configuration, not the calling session.
      KEPT_VARIABLES = /\ACLAUDE_(CONFIG_DIR|CODE_OAUTH_TOKEN|CODE_USE_\w+)\z/

      # @param command [String] the program that resumes and stops sessions
      # @param shell [Shell] runs it
      # @param nice [Array<String>] the niceness prefix of the command line, if any
      # @param patience [Numeric] seconds a stopped session is given to read as stopped
      # @param pause [Numeric] seconds between looks at the listing
      def initialize(command, shell, nice: [], patience: STOP_PATIENCE, pause: 0.25)
        @command = command
        @shell = shell
        @nice = nice
        @patience = patience
        @pause = pause
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

        outcome(id, result)
      end

      private

      def stop(entry)
        return if STOPPED_STATES.include?(entry["state"].to_s)

        name = entry.fetch("id", entry["sessionId"]).to_s
        @shell.capture(@command, "stop", name)
        settle(name)
      end

      # Waits until the listing no longer shows the session running: a resume sent while it does is
      # answered with a copy. Gives up after the patience and resumes anyway.
      def settle(name)
        deadline = Time.now + @patience
        sleep(@pause) while running?(name) && Time.now < deadline
      end

      def running?(name)
        listing = @shell.capture(@command, "agents", "--json", "--all")
        found = listing.ok? && JSON.parse(listing.out).find { |entry| [entry["id"], entry["sessionId"]].include?(name) }
        found ? !STOPPED_STATES.include?(found["state"].to_s) : false
      rescue JSON::ParserError
        false
      end

      # Each inherited `CLAUDE*` variable that names the calling session, unset.
      def cleared
        ENV.keys.select { |name| name.start_with?("CLAUDE") && !KEPT_VARIABLES.match?(name) }.to_h { |name| [name, nil] }
      end

      # The CLI prints `backgrounded · <id>` on stdout, the id the session now runs under, and its
      # `note:` on stderr. An id other than the run's, or a note of a copy, means a copy was started.
      def outcome(id, result)
        at = { value: Time.now.utc.iso8601 }
        named = result.out[ClaudeAgents::SESSION_ID, 1] || result.err[COPY_ID, 1] || id
        note = result.err[COPY_NOTE] || result.out[COPY_NOTE]
        return { resumed_at: at, session: { value: id } } unless note || named != id

        { resumed_at: at, session: { value: named }, note: { value: (note || "started a copy as #{named}").strip } }
      end
    end
  end
end
