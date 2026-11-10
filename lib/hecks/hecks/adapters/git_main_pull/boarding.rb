# frozen_string_literal: true

module Hecks
  module Adapters
    module GitMainPull
      # Which boarded commits the squash-merged trains in a range carried. A train PR lands on
      # `origin/main` as one commit titled "Train: main at <sha>"; the title names the boarded
      # commit, and the claim holds only when that commit holds exactly the squash commit's tree.
      #
      # The answer is not filtered by reachability, by design: a `pull_main` that rebased local
      # `main` past a carried train leaves the boarded commit off `main`, so the tree is the only
      # proof. A caller that needs the commit on a ref (`Carried#carried_boarding`) checks it.
      #
      # An includer has `read` (from `GitWorktrees`), and sets `@git` and `@checkout`.
      module Boarding
        BOARDING = /\ATrain: main at ([0-9a-f]{7,40})/

        private

        # @param range [String] the commits that may be squashes, such as `main..origin/main`
        # @return [Array<String>] the full sha of each boarded commit a squash in `range` carried,
        #   newest squash first
        def boardings(range)
          read("log", "--format=%H %s", range).lines.filter_map do |line|
            squash, subject = line.chomp.split(" ", 2)
            boarded_by(subject.to_s[BOARDING, 1], squash)
          end
        end

        def boarded_by(abbrev, squash)
          return unless abbrev

          sha = read("rev-parse", "--verify", "--quiet", "#{abbrev}^{commit}")
          sha if !sha.empty? && same_tree?(sha, squash)
        rescue ConsoleCapture::Failure
          nil
        end

        def same_tree?(sha, squash) = @git.capture("diff", "--quiet", sha, squash, chdir: @checkout).ok?
      end
    end
  end
end
