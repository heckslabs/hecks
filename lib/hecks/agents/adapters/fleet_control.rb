# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_resolving_shell"
require "hecks/hecks/adapters/claude_transcript"
require_relative "fleet_control/listing"
require_relative "fleet_control/ledger"
require_relative "fleet_control/transcripts"

module Hecks
  module Adapters
    # The `Fleet` port's adapter: the background Claude sessions, listed with the run that holds
    # each, found by what their transcripts say, stopped with `claude stop` and resumed with
    # `claude --bg --resume <id> -n <name>`.
    #
    # It reads the AgentRun ledger and the `PinnedRole` rows ({Ledger}) and writes neither. A
    # refusal names its cause: a session not listed, a pinned role's session to stop, a working
    # session to resume, a command the CLI refused, or a boot with no ledger.
    class FleetControl
      # @param registry [Runtime::Registry, nil] whose ledger and rows are read
      # @param settings [Hash] stand-ins: `shell:` runs `claude`, `projects:` the transcripts'
      #   directory, `runs:` answers the ledger's facts
      def initialize(registry: nil, settings: {})
        @shell = settings[:shell] || ClaudeResolvingShell.new
        @listing = Listing.new(@shell)
        @ledger = Ledger.new(registry, runs: settings[:runs])
        @transcripts = Transcripts.new(settings[:projects] || File.join(Dir.home, ClaudeTranscript::PROJECTS))
      end

      # @return [Hash{Symbol => String}] `text:` one line per listed session, with its run
      # @raise [ConsoleCapture::Failure] when the sessions or the ledger cannot be read
      def sessions(**)
        lines = @listing.entries.map { |entry| line(entry) }
        { text: lines.empty? ? "no session is listed" : lines.join("\n") }
      end

      # @param topic [Hash, String] the words looked for
      # @return [Hash{Symbol => String}] `text:` the sessions that mention it, newest first
      # @raise [ConsoleCapture::Failure] when the topic is blank or the sessions cannot be read
      def topic(topic:, **)
        words = plain(topic)
        raise ConsoleCapture::Failure, "a topic names the words to look for" if words.strip.empty?

        found = mentions(words)
        { text: found.empty? ? "no listed session mentions #{words}" : found.join("\n") }
      end

      # @param session [Hash, String] the session to stop
      # @return [Hash{Symbol => Hash}] `report:` the session stopped, and `run:` the key of the run
      #   that holds it (empty when none does)
      # @raise [ConsoleCapture::Failure] naming why the session was not stopped
      def halt(session:, **)
        entry = listed(plain(session))
        role = @ledger.pinned_role(entry["name"])
        raise ConsoleCapture::Failure, "session #{entry["id"]} holds the pinned role #{role}: it is never stopped" if role

        run!("stop", entry["id"].to_s)
        answer("stopped session #{entry["id"]} (#{entry["name"]}), #{run_text(entry)}", entry)
      end

      # @param session [Hash, String] the session to resume
      # @param name [Hash, String] the name it is resumed under
      # @return [Hash{Symbol => Hash}] `report:` the session resumed and its name, and `run:` the
      #   key of the run that holds it (empty when none does)
      # @raise [ConsoleCapture::Failure] naming why the session was not resumed
      def revive(session:, name:, **)
        entry = listed(plain(session))
        raise ConsoleCapture::Failure, "session #{entry["id"]} is working: only one not working is resumed" if working?(entry)

        full = full_id(entry)
        run!("--bg", "--resume", full, "-n", plain(name), chdir: @transcripts.directory(full))
        answer("resumed session #{entry["id"]} as #{plain(name)}, #{run_text(entry)}", entry)
      end

      private

      def answer(report, entry) = { report: { value: report }, run: { value: @ledger.run_of(full_id(entry))&.first.to_s } }

      def mentions(words)
        newest_first(@listing.entries.filter_map { |entry| mention(entry, words) }).map(&:last)
      end

      def newest_first(found) = found.sort_by(&:first).reverse

      def mention(entry, words)
        said = @transcripts.mention(full_id(entry), words)
        said && [@transcripts.written_at(full_id(entry)), "#{line(entry)}  said: #{said}"]
      end

      def line(entry)
        "#{entry["id"]}  #{entry["name"]}  #{entry["state"]}/#{entry["status"]}  #{run_text(entry)}"
      end

      def run_text(entry)
        key, run = @ledger.run_of(full_id(entry))
        key ? "run #{key} #{run[:status]} #{run[:condition]}".strip : "no run"
      end

      def listed(id)
        @listing.find(id) || raise(ConsoleCapture::Failure, "session #{id} is not listed by claude agents")
      end

      def run!(*arguments, chdir: nil)
        result = @shell.capture("claude", *arguments, chdir: chdir)
        raise ConsoleCapture::Failure, "claude #{arguments.first} refused: #{result.err.strip}" unless result.ok?

        result
      end

      def working?(entry) = entry["state"].to_s == "working" || entry["status"].to_s == "busy"

      def full_id(entry) = (entry.key?("sessionId") ? entry["sessionId"] : entry["id"]).to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
