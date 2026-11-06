# frozen_string_literal: true

require "json"
require_relative "shell"
require_relative "console_capture"
require_relative "claude_transcript"
require_relative "claude_cleaning/worktree_check"
require_relative "dispatching/work_items"

module Hecks
  module Adapters
    # The `Cleaning` port's adapter for `SessionCleanup`: lists the Claude sessions, run sessions
    # and plain ones, says which are safe to remove, and removes those with a plain `claude rm`.
    #
    # A session is safe when it ended `done` or `stopped` (so it is not working or waiting on a
    # person) and its own worktree has no uncommitted files and no commits `origin` lacks. Its own
    # worktree is the one its transcript recorded, not the directory `claude agents` reports. A
    # worktree that is gone counts as safe; a transcript or worktree that cannot be read does not.
    # `--discard-unpushed` is never passed, so `claude rm` itself refuses what the check missed.
    class ClaudeCleaning
      # The command that lists and removes sessions.
      COMMAND = "claude"

      # The states that mean a session ended and waits on nobody.
      ENDED = %w[done stopped].freeze

      # One session as the cleanup judges it.
      #
      # @!attribute [r] id
      #   @return [String] the short id `claude rm` takes
      # @!attribute [r] label
      #   @return [String] the session's kind, `run <key>` or `plain`, and its name
      # @!attribute [r] why_not
      #   @return [String, nil] why it is not safe to remove, nil when it is safe
      Verdict = Struct.new(:id, :label, :why_not) do
        # @return [Boolean] whether the session is safe to remove
        def safe? = why_not.nil?

        # @return [String] the session on one line
        def line = "#{id}  #{label}  #{safe? ? "safe" : "kept: #{why_not}"}"
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `command:` the program (default `claude`), `projects:` the
      #   transcripts directory
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] whose agent runs say which session is a run's
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @command = settings[:command] || COMMAND
        @shell = Shell.new
        @transcript = ClaudeTranscript.new(**settings.slice(:projects))
        @worktrees = WorktreeCheck.new(shell: @shell)
        @runs = Dispatching::WorkItems.new(registry)
      end

      # Says, for every session, whether it is safe to remove and why not. Removes nothing.
      #
      # @param _held [Hash] unused
      # @return [Hash{Symbol => String}] `text:` one line per session
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def removable(**)
        verdicts = judged
        { text: "#{verdicts.empty? ? "no sessions" : verdicts.map(&:line).join("\n")}\n" }
      end

      # Removes every session {#removable} marks safe, with `claude rm` and no `--discard-unpushed`.
      #
      # @param held [Hash] the `SessionCleanup` record: `confirm`
      # @return [Hash{Symbol => Hash}] `report:` a line for each session removed and each kept
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def clean(**)
        lines = judged.map { |verdict| verdict.safe? ? remove(verdict) : "kept  #{verdict.line}" }
        { report: { value: lines.empty? ? "no sessions" : lines.join("\n") } }
      end

      private

      def remove(verdict)
        result = @shell.capture(@command, "rm", verdict.id)
        return "removed  #{verdict.id}  #{verdict.label}" if result.ok?

        "kept  #{verdict.id}  #{verdict.label}  kept: #{@command} rm refused: #{result.err.strip}"
      end

      def judged
        runs = @runs.run_sessions
        listing.map { |entry| verdict(entry, runs) }
      end

      def verdict(entry, runs)
        key = runs.values_at(entry["id"], entry["sessionId"]).compact.first
        label = "#{key ? "run #{key}" : "plain"} #{entry["name"]}".strip
        Verdict.new(entry["id"], label, why_not(entry))
      end

      def why_not(entry)
        state = entry["state"].to_s
        return "still working" if state == "working"
        return "waiting on a person" if state == "blocked"
        return "ended #{state}, not done or stopped" unless ENDED.include?(state)

        worktree_reason(entry["sessionId"].to_s)
      end

      def worktree_reason(full)
        path = @transcript.worktree(full)
        path ? @worktrees.reason(path) : nil
      rescue SystemCallError, JSON::ParserError => e
        "its worktree cannot be found: #{e.message}"
      end

      def listing
        result = @shell.capture(@command, "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "#{@command} could not list sessions: #{result.err.strip}" unless result.ok?

        JSON.parse(result.out).select { |entry| entry["kind"].nil? || entry["kind"] == "background" }
      end
    end
  end
end
