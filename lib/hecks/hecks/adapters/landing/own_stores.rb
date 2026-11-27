# frozen_string_literal: true

require_relative "../delivery_library"

Hecks::Adapters::DeliveryLibrary.require("git_landing")

module Hecks
  module Adapters
    module Landing
      # A landed worktree is retired although it holds the stores it wrote for itself: the Heki
      # snapshots and journals, the SQLite files and the era store that a run in the worktree
      # leaves behind, which git ignores and which nothing reads once the worktree is gone.
      #
      # Only an ignored file whose name is a store's is set aside, so every other ignored file (a
      # local `.env`, an overlay) still keeps the worktree, and an untracked or changed file still
      # does. Every other guard of the vendored `GitLanding::Tidy` holds: the worktree goes only
      # once its branch is on `onto`, without `--force`, and `git worktree remove` takes the stores
      # with it. The override point is `Tidy#status_lines`, whose file is not edited here
      # (ADR 0205).
      module OwnStores
        # The names a store adapter gives the files it writes: Heki's snapshot, journal, lock and
        # temporary file, and SQLite's database with its journal, write-ahead log and shared memory.
        NAMES = %w[*.heki *.heki.journal *.heki.lock *.heki.tmp.* *.db *.db-journal *.db-wal *.db-shm].freeze

        # The directory a file adapter writes the era store under, at any depth.
        ERAS = %r{(\A|/)data/eras/}

        # The prefix `git status --porcelain --ignored` gives an ignored file.
        IGNORED = "!! "

        # @param line [String] one line of `git status --porcelain --ignored`
        # @return [Boolean] whether the line is an ignored file that is one of the worktree's stores
        def self.store?(line)
          return false unless line.start_with?(IGNORED)

          path = line.delete_prefix(IGNORED)
          path.match?(ERAS) || NAMES.any? { |name| File.fnmatch?(name, File.basename(path)) }
        end

        private

        # The lines that keep the worktree, its own ignored stores left out.
        #
        # @param path [String] the worktree's directory
        # @return [Array<String>] what the vendored method answers, less the store lines
        def status_lines(path) = super.reject { |line| OwnStores.store?(line) }
      end
    end
  end
end

Hecks::Adapters::GitLanding::Tidy.prepend(Hecks::Adapters::Landing::OwnStores)
