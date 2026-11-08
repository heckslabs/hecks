# frozen_string_literal: true

require "hecks/hecks/adapters/shell"
require "hecks/hecks/adapters/claude_transcript"
require "hecks/hecks/adapters/claude_cleaning/worktree_check"

module Hecks
  module Adapters
    class Sweeping
      # What a removed session left outside its job directory: the worktree its transcript named and
      # the temp files named for it. It reads, and deletes only the temp files; a worktree is named
      # for `Landing.retire!` or reported, never removed here.
      class Residue
        # @param shell [Shell] runs `git`
        # @param projects [String] the transcripts directory
        # @param tmp [String] the temp directory searched for files named for a session
        def initialize(shell:, projects:, tmp:)
          @shell = shell
          @projects = projects
          @tmp = tmp
          @check = ClaudeCleaning::WorktreeCheck.new(shell: shell)
          @transcripts = ClaudeTranscript.new(projects: projects)
        end

        # @param session [String] a removed session's short id
        # @return [String, nil] a `retire`, `unlanded` or `gone` line for its worktree, nil if none
        def worktree(session)
          id = full(session)
          path = id && @transcripts.worktree(id)
          path && state(path)
        rescue SystemCallError, JSON::ParserError, KeyError
          nil
        end

        # @param session [String] a removed session's short id
        # @return [Array<String>] the temp files named for it
        def temp_files(session)
          Dir.glob(File.join(@tmp, "*#{session}*")).select { |path| File.file?(path) && !File.symlink?(path) }
        end

        private

        def full(session)
          found = Dir.glob(File.join(@projects, "*", "#{session}*.jsonl")).first
          found && File.basename(found, ".jsonl")
        end

        def state(path)
          return "gone  #{path}" unless File.exist?(path)

          why = @check.reason(path) || diverged(path)
          why ? "unlanded  #{path}  #{why}" : "retire  branch=#{branch(path)}  checkout=#{path}"
        end

        def diverged(path)
          @shell.capture("git", "-C", path, "diff", "--quiet", "main...HEAD").ok? ? nil : "its commits are not on main"
        end

        def branch(path) = @shell.capture("git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD").out.strip
      end
    end
  end
end
