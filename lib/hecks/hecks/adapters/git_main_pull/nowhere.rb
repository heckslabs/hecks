# frozen_string_literal: true

require "tmpdir"

module Hecks
  module Adapters
    module GitMainPull
      # Bringing a diverged `main` up to date when no worktree has it checked out, so there is no
      # checkout to rebase in: the ref is moved, never a working tree.
      #
      # When `main` and `origin/main` hold the same tree, `main`'s unpushed commits went out as one
      # squash commit, and the ref moves to `origin/main`. Otherwise the commits are rebased in a
      # temporary detached worktree that is removed afterwards, and the ref moves to the result. A
      # conflict leaves `main` where it was.
      #
      # An includer is `GitMainPull`, which has the `GitWorktrees` helpers and sets `@git`.
      module Nowhere
        private

        # @return [String] what was done, one line
        # @raise [ConsoleCapture::Failure] naming `cannot pull main` when the rebase conflicts
        def pull_unhosted_main(ahead, behind)
          return carried_by_squash if read("rev-parse", "main^{tree}") == read("rev-parse", "#{REMOTE_MAIN}^{tree}")

          note = carried_note
          rebased = rebase_detached(ahead)
          move_main(rebased)
          "main rebased #{ahead} unpushed commits onto #{REMOTE_MAIN} (#{behind} new) at #{short(rebased)}, " \
            "checked out nowhere#{note}"
        end

        def carried_by_squash
          move_main(read("rev-parse", "#{REMOTE_MAIN}^{commit}"))
          "main carried by squash: its tree equals #{REMOTE_MAIN}, moved to #{short(read("rev-parse", "main"))}"
        end

        # Moves the `main` ref only if it still stands where it was read.
        def move_main(sha) = read("update-ref", "refs/heads/main", sha, read("rev-parse", "refs/heads/main"))

        def rebase_detached(ahead)
          Dir.mktmpdir("hecks-pull-main") do |parent|
            tree = File.join(parent, "tree")
            read("worktree", "add", "--detach", tree, "main")
            begin
              rebase_in(tree, ahead)
            ensure
              @git.capture("worktree", "remove", "--force", tree, chdir: @checkout)
            end
          end
        end

        def rebase_in(tree, ahead)
          result = @git.capture(*rebase_args, chdir: tree)
          return read("rev-parse", "HEAD", dir: tree) if result.ok?

          refuse_conflict(tree, ahead)
        end
      end
    end
  end
end
