# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class ClaudeCleaning
      # Turns one row of Roundhouse's `Ended` meter into the facts Signalbox's `Reaping.Rule` is
      # asked with (ADR 0222, phase 3, reaping): what Delegate knows of the subject beside the
      # meter (its pin, its run, the work its worktree holds, whether a person spoke in it) and
      # the keep window the Signalbox world gives it. It decides nothing.
      class ReapFacts
        # What Delegate reads beside the meter, and `hold`, the hand run holding a session or copy.
        #
        # @!attribute [r] window
        #   @return [KeepWindow] says whether a pin keeps a session
        # @!attribute [r] jobs
        #   @return [ClaudeJobs] says whether the pipeline launched a session
        # @!attribute [r] transcript
        #   @return [ClaudeTranscript] says where a session worked and whether a person spoke in it
        # @!attribute [r] worktrees
        #   @return [WorktreeCheck] counts a worktree's unsaved files and commits
        # @!attribute [r] runs
        #   @return [Dispatching::WorkItems] the started work items and runs
        Sources = Struct.new(:window, :jobs, :transcript, :worktrees, :runs, :hold, keyword_init: true)

        # @param sources [Sources] what Delegate reads beside the meter
        # @param keeps [Hash] the Signalbox world's `reaping` line and its `fuses:` line
        def initialize(sources, keeps)
          @window, @jobs, @transcript, @worktrees, @runs, @hold = sources.to_a
          @keeps = keeps
        end

        # @param row [Hash] one session row of the meter
        # @param pass [String] the reap pass the ruling's key is under
        # @return [Hash{Symbol => Object}] the `Reaping.Rule` arguments
        def session(row, pass)
          role = role(row)
          { reaping: "#{pass}:#{row[:id]}", subject: subject(row), kind: row[:kind], state: word(row[:state]),
            role: role, live: row[:live], idle: row[:idle_minutes].to_i, keep: keep(row, role),
            **held(row), landed: "no" }
        end

        # @param row [Hash] one copy row of the meter
        # @param pass [String] the reap pass the ruling's key is under
        # @return [Hash{Symbol => Object}] the `Reaping.Rule` arguments
        def copy(row, pass)
          { reaping: "#{pass}:copy:#{row[:branch]}", subject: row[:branch], kind: "copy", state: "none",
            role: "copy", live: "no", idle: row[:idle_minutes].to_i, keep: minutes(:ended_minutes),
            unsaved: row[:unsaved].to_i, pinned: "no", open: answer(copy_open?(row)), landed: row[:landed] }
        end

        private

        def subject(row) = row[:id].to_s.empty? ? row[:session].to_s : row[:id].to_s

        def word(text) = text.to_s.strip.empty? ? "none" : text.to_s

        def role(row)
          return "person" if @transcript.taken_over?(row[:session].to_s)

          row[:role].to_s.empty? ? "helper" : row[:role].to_s
        end

        def held(row)
          { unsaved: unsaved(row[:session].to_s), pinned: answer(@window.pin({ "id" => row[:id], "name" => row[:name] })),
            open: answer(row[:run_status].to_s == "started" || handheld?(row)) }
        end

        # A finished session is kept the ended window, the owner's own the owner window; a stale one
        # is kept its role's fuse time rating.
        def keep(row, role)
          return fuse_minutes(role) if row[:kind] == "stale"

          owner?(row) ? minutes(:owner_minutes) : minutes(:ended_minutes)
        end

        def owner?(row) = row[:run].to_s.empty? && @jobs.launched_by(row[:id].to_s).empty?

        def fuse_minutes(role)
          fuses = @keeps.fetch(:fuses, {})
          rated = :"#{role}_minutes"
          (fuses.key?(rated) ? fuses[rated] : fuses[:helper_minutes]).to_i
        end

        def minutes(name) = @keeps[name].to_i

        # An unreadable worktree counts as one unsaved file, so its session is never reaped.
        def unsaved(session)
          path = @transcript.worktree(session).to_s
          return 0 if path.empty? || !File.directory?(path)

          @worktrees.uncommitted(path) + @worktrees.ahead(path)
        rescue SystemCallError, JSON::ParserError
          1
        end

        def copy_open?(row)
          branch = row[:branch].to_s
          row[:held] == "yes" || !@hold&.checkout(row[:path]).nil? || started?(branch)
        end

        def started?(branch)
          @runs.started.any? { |item| item.key == branch } ||
            @runs.runs.any? { |key, run| key == branch && run[:status] == "started" }
        end

        # Whether a registered hand run holds the session, whose own worktree it may work in.
        def handheld?(row)
          path = @transcript.worktree(row[:session].to_s).to_s
          !(@hold&.session(row[:session].to_s) || @hold&.session(row[:id].to_s) || @hold&.checkout(path)).nil?
        end

        def answer(yes) = yes ? "yes" : "no"
      end
    end
  end
end
