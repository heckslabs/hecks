# frozen_string_literal: true

require "time"
require_relative "shell"

module Hecks
  module Adapters
    # Reads whether a started run's session still shows signs of life, without `claude`: a process
    # in the process table that names the session or its directory, a commit the directory holds
    # that `origin` lacks, and files changed in it.
    #
    # It decides nothing. How long without any of them makes a run gone is {RunGone}'s, from the
    # world.
    class RunActivity
      # @param shell [Shell] runs `ps` and `git`
      def initialize(shell: Shell.new)
        @shell = shell
      end

      # The marker of a linked worktree's path. A run that works in the checkout's own root names a
      # directory that every hecks process names too, so only a linked worktree is a sign of life.
      WORKTREES = "/.claude/worktrees/"

      # @param session [String] the session id the run holds
      # @param directory [String] the run's worktree
      # @return [Boolean] whether a process's command line names the session, or the directory when
      #   it is a linked worktree
      def process?(session, directory)
        names = [session, linked(directory)].map(&:to_s).reject(&:empty?)
        lines = @shell.capture("ps", "-axo", "command").out.lines
        lines.any? { |line| names.any? { |name| line.include?(name) } }
      end

      # @param directory [String] the run's worktree
      # @return [Time, nil] the latest of the newest commit `origin` lacks and the newest change to
      #   a file git lists as changed or untracked; nil when there is none or the directory is gone
      def last_at(directory)
        return nil unless linked(directory) && File.directory?(directory.to_s)

        [committed_at(directory), changed_at(directory)].compact.max
      end

      private

      # The directory when it is a linked worktree, nil for the checkout's own root, whose
      # commits and changed files belong to whoever works there.
      def linked(directory) = (directory.to_s if directory.to_s.include?(WORKTREES))

      def committed_at(directory)
        said = @shell.capture("git", "-C", directory, "log", "-1", "--format=%ct", "HEAD", "--not", "--remotes=origin")
        Time.at(said.out.strip.to_i).utc if said.ok? && !said.out.strip.empty?
      end

      def changed_at(directory)
        said = @shell.capture("git", "-C", directory, "status", "--porcelain")
        return nil unless said.ok?

        times = paths(said.out).filter_map { |path| mtime(File.join(directory, path)) }
        times.max
      end

      # The paths a `status --porcelain` listing names; a rename names where the file went.
      def paths(listing)
        names = listing.lines.map { |line| line[3..].to_s.strip }
        names.map { |name| name.split(" -> ").last.to_s }
      end

      def mtime(path) = (File.mtime(path) if File.exist?(path))
    end
  end
end
