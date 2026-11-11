# frozen_string_literal: true

require "fileutils"
require_relative "../shell"

module Hecks
  module Adapters
    # Clears the scratch a finished run leaves in its worktree (`tmp`, `.ruby-lsp`, a crate's
    # `target`), so the worktree can be retired.
    #
    # Only a path the world's `worktree_scratch` list names is a candidate, and only when git says
    # it is ignored and holds no tracked file. A tracked file, or one that is untracked and not
    # ignored, is never touched, whatever the list says.
    class WorktreeScratch
      # @param globs [Array<String>] paths relative to the worktree that may hold scratch
      # @param shell [Shell] runs `git`
      def initialize(globs:, shell: Shell.new)
        @globs = globs
        @shell = shell
      end

      # @param path [String] the worktree's directory
      # @return [Hash{Symbol => Array<String>}] `cleared:` the paths removed, `kept:` the listed
      #   paths that exist but are not scratch
      def clear(path)
        found = matches(path)
        cleared, kept = found.partition { |relative| scratch?(path, relative) }
        cleared.each { |relative| FileUtils.rm_rf(File.join(path, relative)) }
        { cleared: cleared, kept: kept }
      end

      private

      def matches(path)
        found = @globs.flat_map { |glob| Dir.glob(File.join(path, glob), File::FNM_DOTMATCH) }
        relative(path, found).uniq.sort
      end

      def relative(path, found)
        found.reject { |entry| entry.end_with?("/.", "/..") }.map { |entry| entry.delete_prefix("#{path}/") }
      end

      def scratch?(path, relative) = ignored?(path, relative) && !tracked?(path, relative)

      def ignored?(path, relative) = git(path, "check-ignore", "-q", "--", relative).ok?

      def tracked?(path, relative)
        listed = git(path, "ls-files", "--", relative)
        !listed.ok? || !listed.out.strip.empty?
      end

      def git(path, *) = @shell.capture("git", "-C", path, *)
    end
  end
end
