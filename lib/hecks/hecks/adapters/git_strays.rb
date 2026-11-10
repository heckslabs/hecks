# frozen_string_literal: true

require_relative "../../text"
require_relative "git_strays/looking"
require_relative "git_strays/shelf"

module Hecks
  module Adapters
    # What the untracked and changed paths of a checkout are. It only reads.
    #
    # It names each path's kind, so a dirty checkout that blocks a landing can be understood
    # without a raw `git status`: a stale copy of a file `main` deleted, a linked worktree sitting
    # inside the checkout, a tracked file with uncommitted changes, or unknown. `Shelf` moves one
    # out of the way.
    class GitStrays
      include Looking

      # @param git [Git] the adapter every git call goes through
      # @param checkout [String] the repository's top level
      def initialize(git, checkout)
        @git = git
        @checkout = checkout
      end

      # @return [String] one tab-separated line per path: the path, its kind and what to know
      #   about it, or `no strays` when the checkout is clean
      def report
        lines = untracked.flat_map { |entry| lines_for(entry) } + changed_tracked.map { |entry| tracked_line(entry) }
        lines.empty? ? "no strays" : lines.join("\n")
      end

      private

      # The untracked entries `git status` lists, the ones that block a landing: files, and
      # directories that hold nothing tracked. A directory of ignored files is not among them.
      def untracked
        out = capture("status", "--porcelain", "-z", "--untracked-files=normal")
        out.split("\0").select { |entry| entry.start_with?("?? ") }.map { |entry| entry.delete_prefix("?? ") }
      end

      # One line for an entry, or one per linked worktree a directory entry holds.
      def lines_for(entry)
        trees = trees_in(File.join(@checkout, entry.chomp("/")))
        return trees.map { |tree| tree_line(tree) } unless trees.empty?

        kind, detail = stale_detail(entry)
        [[entry, kind, detail].join("\t")]
      end

      def tree_line(tree)
        kind, detail = tree_detail(tree)
        ["#{tree.path.delete_prefix("#{root}/")}/", kind, detail].join("\t")
      end

      def tracked_line(entry)
        said = "a tracked file with uncommitted changes (#{entry[0, 2].strip}); commit it or leave it to its owner"
        [entry[3..], "changed", said].join("\t")
      end

      def tree_detail(tree)
        state = tree.branch ? "branch #{tree.branch}" : "detached #{short(tree.head)}"
        saved = dirty(tree.path).empty? ? "clean" : "dirty"
        ["worktree", "#{state}; #{saved}; #{commits_verdict(tree, saved)}"]
      end

      # What a tree's commits say about moving it. A head whose commits cannot be counted is kept,
      # and the line says why, since an uncounted head may hold work nothing else has.
      def commits_verdict(tree, saved)
        off_main, off_remote = unreachable(tree.head)
        verdict = saved == "clean" && off_remote.zero? ? "safe to move: Landing.set_aside!" : "keep: unsaved or unpushed work"
        "#{off_main} commit(s) not on main, #{off_remote} on no main or remote ref; #{verdict}"
      rescue ConsoleCapture::Failure => e
        "commits unreadable (#{Hecks::Text.first_line(e.message)}); keep: its commits could not be counted"
      end

      # A file main deleted is stale and recoverable; anything else is unknown.
      def stale_detail(entry)
        path = entry.chomp("/")
        removed = entry.end_with?("/") ? nil : removal(path)
        return ["unknown", "not tracked and not a worktree; nothing in history names it"] unless removed

        sha, subject = removed
        same = identical?(sha, path) ? "identical to its last version" : "differs from its last version"
        ["stale", "main deleted it in #{sha} (#{subject}); #{same}; recoverable: git show #{sha}^:#{path}"]
      end

      def removal(path)
        found = capture("log", "-1", "--diff-filter=D", "--format=%h\t%s", "main", "--", path).strip
        found.empty? ? nil : found.split("\t", 2)
      rescue ConsoleCapture::Failure
        nil
      end

      def identical?(sha, path)
        capture("show", "#{sha}^:#{path}").b == File.binread(File.join(@checkout, path))
      rescue ConsoleCapture::Failure
        false
      end
    end
  end
end
