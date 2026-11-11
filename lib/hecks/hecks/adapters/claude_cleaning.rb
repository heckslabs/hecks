# frozen_string_literal: true

require "json"
require_relative "shell"
require_relative "console_capture"
require_relative "claude_transcript"
require_relative "claude_cleaning/worktree_check"
require_relative "claude_cleaning/candidate_rule"
require_relative "claude_cleaning/reaping"
require_relative "dispatching/work_items"

module Hecks
  module Adapters
    # The `Cleaning` port's adapter for `SessionCleanup`: lists the Claude sessions, says which are
    # safe to remove, and removes those with a plain `claude rm`.
    #
    # Only the session of a dispatched run is ever a candidate: the AgentRun ledger binds a run to
    # it, that run is `finished` with condition `done`, the listing says `done` and no person spoke
    # in it ({CandidateRule}). A session with no run, a blocked or working one, one a person
    # stopped and the pruner's own are kept by name, whatever `claude agents` lists. A candidate is
    # then safe when its own worktree, the one its transcript recorded, has no uncommitted files
    # and no commits `origin` lacks. Just before each `claude rm` it asks again whether a person
    # spoke in the session. `--discard-unpushed` is never passed, so `claude rm` itself refuses what
    # the check missed.
    class ClaudeCleaning
      include Reaping

      # The command that lists and removes sessions.
      COMMAND = "claude"

      # One session as the cleanup judges it.
      #
      # @!attribute [r] id
      #   @return [String] the short id `claude rm` takes
      # @!attribute [r] label
      #   @return [String] the session's kind, `run <key>` or `plain`, and its name
      # @!attribute [r] why_not
      #   @return [String, nil] why it is not safe to remove, nil when it is safe
      # @!attribute [r] entry
      #   @return [Hash] the session as `claude agents` listed it
      Verdict = Struct.new(:id, :label, :why_not, :entry) do
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
        @registry = registry
        @tuning = settings
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
        spoken = @rule.spoken(verdict.entry)
        return "kept  #{verdict.id}  #{verdict.label}  kept: #{spoken}" if spoken

        result = @shell.capture(@command, "rm", verdict.id)
        return "removed  #{verdict.id}  #{verdict.label}" if result.ok?

        "kept  #{verdict.id}  #{verdict.label}  kept: #{@command} rm refused: #{result.err.strip}"
      end

      def judged
        sessions = @runs.run_sessions
        @rule = CandidateRule.new(runs: @runs.runs, transcript: @transcript)
        listing.map { |entry| verdict(entry, sessions.values_at(entry["id"], entry["sessionId"]).compact.first) }
      end

      def verdict(entry, key)
        label = "#{key ? "run #{key}" : "plain"} #{entry["name"]}".strip
        Verdict.new(entry["id"], label, @rule.why_not(entry, key) || worktree_reason(entry["sessionId"].to_s), entry)
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
