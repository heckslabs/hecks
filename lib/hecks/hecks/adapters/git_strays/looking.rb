# frozen_string_literal: true

require_relative "../git_worktrees"

module Hecks
  module Adapters
    class GitStrays
      # What the reading and the moving of strays both ask of a checkout: the linked worktrees at or
      # under a path, how many of a head's commits exist nowhere safe, and git's answers unstripped.
      #
      # An includer sets `@git` (the `Git` adapter) and `@checkout` (the repository's top level).
      module Looking
        include GitWorktrees

        private

        # Runs git in the checkout and answers what it printed, leading blanks kept.
        def capture(*args)
          result = @git.capture(*args, chdir: @checkout)
          raise ConsoleCapture::Failure, "git #{args.first} failed in #{@checkout}: #{result.err.strip}" unless result.ok?

          result.out
        end

        # Tracked files with changes, as `XY path` lines; the first line keeps its status column.
        def changed_tracked = capture("status", "--porcelain", "--untracked-files=no").lines.map(&:rstrip)

        def root = File.realpath(@checkout)

        def realpath(full) = File.exist?(full) ? File.realpath(full) : full

        def linked_tree_at(full) = worktrees.drop(1).find { |tree| realpath(tree.path) == realpath(full) }

        # The linked worktrees at a path or anywhere under it.
        def trees_in(full)
          here = realpath(full)
          worktrees.drop(1).select { |tree| realpath(tree.path).then { |at| at == here || at.start_with?("#{here}/") } }
        end

        # How many commits a head holds that main lacks, and how many of those no remote has either.
        def unreachable(head)
          [count("main..#{head}"), read("rev-list", "--count", head, "--not", "main", "--remotes").to_i]
        rescue ConsoleCapture::Failure
          [0, 0]
        end
      end
    end
  end
end
