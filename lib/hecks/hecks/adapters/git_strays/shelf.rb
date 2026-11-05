# frozen_string_literal: true

require "fileutils"
require_relative "looking"

module Hecks
  module Adapters
    class GitStrays
      # Moves one untracked path, or one clean linked worktree whose commits are all on `main` or a
      # remote, out of a checkout into a holding directory.
      #
      # It never deletes, never touches a tracked file or a path with unsaved work, never overwrites
      # an earlier move, and says where the path went and how to put it back.
      class Shelf
        include Looking

        # Where a path goes when no holding directory is named and no job directory is set.
        FALLBACK_HOLDING = File.join(Dir.home, ".claude", "set-aside")

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param path [String] the path, relative to the checkout or inside it
        # @param holding [String, nil] the directory to move it into; the job's `tmp` directory,
        #   else `~/.claude/set-aside`
        # @return [String] where it went and the command that puts it back
        # @raise [ConsoleCapture::Failure] for a tracked path, one with unsaved work, a worktree
        #   that is dirty, unpushed, in use or the primary, or a path outside the checkout
        def move(path, holding: nil)
          full = inside(path)
          tree = linked_tree_at(full)
          refuse_unsafe(full) unless tree
          destination = free_name(holding || default_holding, File.basename(full))
          FileUtils.mkdir_p(File.dirname(destination))
          tree ? move_tree(tree, destination) : FileUtils.mv(full, destination)
          "moved #{full} to #{destination}; put it back with: #{tree ? "git worktree move" : "mv"} #{destination} #{full}"
        end

        private

        def default_holding
          job = ENV.fetch("CLAUDE_JOB_DIR", nil)
          job ? File.join(job, "tmp") : FALLBACK_HOLDING
        end

        def free_name(directory, name)
          stem = File.join(directory, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{name}")
          taken = 0
          taken += 1 while File.exist?(taken.zero? ? stem : "#{stem}-#{taken}")
          taken.zero? ? stem : "#{stem}-#{taken}"
        end

        # The path, inside the checkout and outside `.git`, that exists.
        def inside(path)
          full = File.expand_path(path, @checkout)
          here = realpath(full)
          refuse("#{path} is not inside #{@checkout}") unless here.start_with?("#{root}/")
          refuse("#{path} is inside .git, which is never moved") if git_dir?(here)
          refuse("#{path} does not exist in #{@checkout}") unless File.exist?(full)

          full
        end

        def git_dir?(here) = here == File.join(root, ".git") || here.start_with?("#{root}/.git/")

        # A directory that holds a worktree, a tracked file, or a tracked file with changes stays.
        def refuse_unsafe(full)
          relative = full.delete_prefix("#{root}/")
          holds = trees_in(full)
          refuse("#{relative} holds the linked worktree #{holds.first.path}; set that one aside") unless holds.empty?

          held = capture("ls-files", "-z", "--", relative).split("\0")
          refuse("#{relative} is tracked (#{held.first(3).join(", ")}); only untracked paths move") unless held.empty?
        end

        def refuse(message) = raise(ConsoleCapture::Failure, message)

        def move_tree(tree, destination)
          refuse_in_use(tree)
          saved = dirty(tree.path)
          refuse("#{tree.path} holds uncommitted work: #{saved.join(", ")}") unless saved.empty?

          _, off_remote = unreachable(tree.head)
          refuse("#{tree.path} has #{off_remote} commit(s) on no main or remote ref; push them first") unless off_remote.zero?

          read("worktree", "move", tree.path, destination)
        end

        def refuse_in_use(tree)
          return unless Dir.pwd == tree.path || Dir.pwd.start_with?("#{tree.path}/")

          refuse("#{tree.path} is the directory this process stands in")
        end
      end
    end
  end
end
