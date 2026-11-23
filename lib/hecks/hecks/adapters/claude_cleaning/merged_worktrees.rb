# frozen_string_literal: true

require_relative "../shell"
require_relative "worktree_check"

module Hecks
  module Adapters
    class ClaudeCleaning
      # Retires the coder worktrees whose branch is on `main` and which nothing holds, under a
      # checkout's `.claude/worktrees` and under any directory listed in `outside:`: the ones no
      # session lists, which the sweep of sessions never reaches. Every live worktree is a
      # directory the file-event daemon watches, so a landed one costs CPU for nothing.
      #
      # A worktree is kept, and named with the reason, when it is on no branch or on `main`, when
      # its Work is still open, when it is younger than the window, when it holds an uncommitted
      # file or a commit no branch on `origin` holds, or when the retirement refuses it. At most
      # `cap` are retired in one sweep, whichever directory they stand in.
      class MergedWorktrees
        # How many worktrees one sweep retires.
        CAP = 10

        # @param root [String] the primary checkout
        # @param window_minutes [Integer] how long a worktree stands before it can be retired
        # @param open [#call] given a branch name, whether its Work is still open
        # @param retire [#call] given a worktree's path, removes it; raises when it holds work
        # @param more [Hash] `outside:` directories, besides `.claude/worktrees`, whose worktrees
        #   are swept too; `now:` the clock answering a Time, `cap:` the most worktrees one sweep
        #   retires, `check:` a {WorktreeCheck} and `shell:` a {Shell}
        def initialize(root:, window_minutes:, open:, retire:, **more)
          @root = File.realpath(root)
          @window = window_minutes.to_i * 60
          @open = open
          @retire = retire
          @now = more[:now] || -> { Time.now }
          @cap = more[:cap] || CAP
          @homes = homes(more[:outside])
          @shell = more[:shell] || Shell.new
          @check = more[:check] || WorktreeCheck.new(shell: @shell)
        end

        # @return [Hash{Symbol => Array}] `removed:` the retired worktrees' names and `kept:` each
        #   kept one as `[name, reason]`
        def sweep
          result = { removed: [], kept: [] }
          worktrees.each { |tree| settle(tree, result) }
          result
        end

        private

        # The directories a swept worktree may stand under, as real paths ending in a separator, so
        # a sibling that shares a prefix never matches; a directory that is not there is skipped.
        def homes(outside)
          dirs = [File.join(@root, ".claude", "worktrees")] + Array(outside)
          dirs.filter_map { |dir| File.realpath(dir) + File::SEPARATOR if File.directory?(dir) }
        end

        def settle(tree, result)
          name = File.basename(tree[:path])
          why = result[:removed].length >= @cap ? "retired enough this sweep" : refusal(tree)
          why ||= retirement(tree[:path])
          why ? result[:kept] << [name, why] : result[:removed] << name
        end

        def refusal(tree)
          branch = tree[:branch]
          return "on no branch or on main" if branch.nil? || branch == "main"
          return "its Work is still open" if @open.call(branch)
          return "younger than the window" if young?(tree[:path])

          @check.reason(tree[:path])
        end

        def retirement(path)
          @retire.call(path)
          nil
        rescue StandardError => e
          first_line(e.message)
        end

        def first_line(text) = text.lines.fetch(0, "").strip

        # The admin directory's `HEAD` file is written when the worktree is cut or its branch is
        # switched, so its time is the worktree's age, not the time of its last file change.
        def young?(path)
          dir = @shell.capture("git", "-C", path, "rev-parse", "--absolute-git-dir").out.strip
          head = File.join(dir, "HEAD")
          !File.exist?(head) || @now.call - File.mtime(head) < @window
        end

        def worktrees
          out = @shell.capture("git", "-C", @root, "worktree", "list", "--porcelain").out
          out.split("\n\n").filter_map { |block| entry(block) }
        end

        def entry(block)
          lines = block.lines.map(&:strip)
          path = lines.find { |line| line.start_with?("worktree ") }.to_s.delete_prefix("worktree ")
          return unless @homes.any? { |home| path.start_with?(home) }

          ref = lines.find { |line| line.start_with?("branch ") }
          { path: path, branch: ref&.delete_prefix("branch refs/heads/") }
        end
      end
    end
  end
end
