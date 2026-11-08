# frozen_string_literal: true

module Hecks
  module Adapters
    module GitMainPull
      # Recognising a train that origin squash-merged: the PR carried `main` up to a boarded commit
      # as one commit titled "Train: main at <sha>", so the commits of local `main` up to that sha
      # are already on `origin/main` and only the ones after it still need to move.
      #
      # The title names the boarded commit, and the claim is checked on the trees: the boarded
      # commit must be reachable from the ref asked about and hold exactly the squash commit's tree.
      #
      # An includer is `GitMainPull`, which has the `GitWorktrees` helpers and sets `@git`.
      module Carried
        BOARDING = /\ATrain: main at ([0-9a-f]{7,40})/

        private

        # @param range [String] the commits that may be the squash, such as `main..origin/main`
        # @param within [String] the ref the boarded commit must be reachable from
        # @return [String, nil] the full sha of the boarded commit the squash carried, if any
        def carried_boarding(range = "main..#{REMOTE_MAIN}", within = "main")
          read("log", "--format=%H %s", range).lines.each do |line|
            squash, subject = line.chomp.split(" ", 2)
            sha = boarded_commit(subject[BOARDING, 1], squash, within)
            return sha if sha
          end
          nil
        end

        def boarded_commit(abbrev, squash, within)
          return unless abbrev

          sha = read("rev-parse", "--verify", "--quiet", "#{abbrev}^{commit}")
          sha if !sha.empty? && ancestor?(sha, within) && same_tree?(sha, squash)
        rescue ConsoleCapture::Failure
          nil
        end

        def same_tree?(sha, squash) = @git.capture("diff", "--quiet", sha, squash, chdir: @checkout).ok?

        # The arguments of the rebase onto `origin/main`: after a carried train, only what follows
        # the boarded commit.
        def rebase_args
          boarded = carried_boarding
          args = ["rebase", "--rebase-merges"]
          boarded ? args + ["--onto", REMOTE_MAIN, boarded] : args + [REMOTE_MAIN]
        end

        # @return [String] the carried range and the commits rebased, or an empty string
        def carried_note
          boarded = carried_boarding
          return "" unless boarded

          base = read("merge-base", "main", REMOTE_MAIN)
          after = read("log", "--format=%h", "--reverse", "#{boarded}..main").split
          " (carried by squash: #{count("#{base}..#{boarded}")} commits #{short(base)}..#{short(boarded)}; " \
            "rebased #{after.size} after it: #{after.join(", ")})"
        end
      end
    end
  end
end
