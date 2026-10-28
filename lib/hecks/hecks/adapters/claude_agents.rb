# frozen_string_literal: true

require "json"
require_relative "shell"
require "time"
require_relative "console_capture"
require_relative "claude_transcript"

module Hecks
  module Adapters
    # The `Agents` port's adapter for `AgentRun`: finds the directory a session will work in, starts
    # a background Claude session there with the `claude` command, and reports the state a started
    # session says it is in.
    #
    # It decides nothing. Whether a brief is enough, whether an agent name is acceptable and which
    # states mean a session has ended are the bluebook's; this only looks, starts and reads. The
    # command is an argument list, never a string for a shell, and a `--` keeps a brief from being
    # taken for a flag.
    class ClaudeAgents
      # The command that starts and lists sessions.
      COMMAND = "claude"

      # A background start prints `backgrounded · <id>` first, then how to attach to the session.
      SESSION_ID = /\Abackgrounded\W+([0-9A-Za-z][0-9A-Za-z_-]{5,})/

      # Keeps the command to run, so a spec can point it at a stand-in.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `command:` the program that starts sessions (default `claude`)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @command = settings[:command] || COMMAND
        @shell = Shell.new
        @transcript = ClaudeTranscript.new(**settings.slice(:projects))
      end

      # Says the directory a session would work in is there.
      #
      # @param held [Hash] the `AgentRun` record: `repo`
      # @return [Hash{Symbol => Hash}] `report:` that the directory is there
      # @raise [ConsoleCapture::Failure] when it is not a directory
      def locate(**held)
        repo = plain(held[:repo])
        raise ConsoleCapture::Failure, "#{repo} is not a directory" unless File.directory?(repo.to_s)

        { report: { value: "#{repo} is a directory" } }
      end

      # Starts a background session in the directory, with the brief as its first prompt.
      #
      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when one is named
      # @return [Hash{Symbol => Hash}] `session:` the id the session is known by
      # @raise [ConsoleCapture::Failure] when the command fails or names no session
      def start(**held)
        result = @shell.capture(*start_arguments(held), chdir: plain(held[:repo]))
        raise ConsoleCapture::Failure, "#{@command} did not start a session: #{result.err.strip}" unless result.ok?

        id = result.out[SESSION_ID, 1]
        raise ConsoleCapture::Failure, "#{@command} named no session: #{result.out.strip}" unless id

        { session: { value: id } }
      end

      # Reads the state a started session reports.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => String}] `condition:` the state the session reports, as a bare
      #   string
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed or this one is not among
      #   them
      def examine(**held)
        { condition: listed(plain(held[:session]))["state"].to_s }
      end

      # Says whether a person replied in a session after its brief.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `taken_over:` true when a person replied or the transcript
      #   cannot be read, and `note:` that fact in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed or this one is not among
      #   them
      def review(**held)
        full = listed(plain(held[:session]))["sessionId"]
        taken = @transcript.taken_over?(full)
        { taken_over: taken, note: taken ? "a person replied, or the transcript cannot be read" : "nobody replied" }
      end

      # Removes a session with `claude rm`.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `removed_at:` when it was removed, as an ISO 8601 string
      # @raise [ConsoleCapture::Failure] when the command refuses
      def remove(**held)
        id = plain(held[:session])
        result = @shell.capture(@command, "rm", id)
        raise ConsoleCapture::Failure, "#{@command} rm #{id} refused: #{result.err.strip}" unless result.ok?

        { removed_at: { value: Time.now.utc.iso8601 } }
      end

      private

      def listed(id)
        listing = @shell.capture(@command, "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "#{@command} could not list sessions: #{listing.err.strip}" unless listing.ok?

        found = JSON.parse(listing.out).find { |entry| [entry["id"], entry["sessionId"]].include?(id) }
        found || raise(ConsoleCapture::Failure, "no session #{id} is listed")
      end

      def start_arguments(held)
        agent = plain(held[:agent])
        [@command, *(agent ? ["--agent", agent] : []), "--bg", "--", plain(held[:brief])]
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
