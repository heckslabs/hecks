# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # Brings local main level with its remote by merging, never by rebasing: the commits main
      # holds that are not pushed keep their hashes, so the branches and open trains built on them
      # stay beneath main. A remote that is only ahead is a fast-forward; a diverged one gets a
      # merge commit. A conflict on the shape ledger takes the remote's copy (the ledger is
      # settled after); any other conflict abandons the merge and names the paths.
      class MainMerge
        include Reading

        # A committer for the merge commit, when git knows no one.
        FALLBACK = %w[-c user.name=Hecks -c user.email=hecks@localhost].freeze

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level, with main checked out and clean
        # @param tracking [String] the remote branch merged in, such as `origin/main`
        # @param ledger [String] the path whose conflict takes the remote's copy
        def initialize(git, checkout, tracking:, ledger:)
          @git = git
          @checkout = checkout
          @tracking = tracking
          @ledger = ledger
        end

        # @return [void]
        # @raise [ConsoleCapture::Failure] when the merge conflicts outside the ledger
        def run
          result = git(*identity, "merge", "--no-edit", @tracking)
          return if result.ok?

          conflicted = read("diff", "--name-only", "--diff-filter=U").lines.map(&:strip)
          return abandon(conflicted) unless conflicted == [@ledger]

          read("checkout", "--theirs", "--", @ledger)
          read("add", "--", @ledger)
          read(*identity, "-c", "core.editor=true", "commit", "--no-edit")
        end

        private

        def abandon(conflicted)
          git("merge", "--abort")
          raise ConsoleCapture::Failure,
                "main does not merge with #{@tracking}: conflict in #{conflicted.join(", ")}; resolve them by hand"
        end

        def identity = read("config", "user.email").strip.empty? ? FALLBACK : []

        def git(*) = @git.capture(*, chdir: @checkout)
      end
    end
  end
end
