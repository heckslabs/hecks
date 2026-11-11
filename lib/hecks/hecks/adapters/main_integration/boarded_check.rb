# frozen_string_literal: true

require_relative "../git"
require_relative "command_runner"

module Hecks
  module Adapters
    class MainIntegration
      # Whether a train pull request is open for a landed commit, whoever boarded it (the listener,
      # `SendTrain.board!` by hand, another session). The train pushes each boarding to a branch
      # named for the boarded commit (`train/main-<12 characters>`); a branch whose commit is the
      # landed one or a descendant of it, and whose pull request is still open, means CI is
      # already judging the commit, so verifying it answers nothing. A branch whose pull request
      # was closed or merged does not count: a closed one is retried by verifying again, and a
      # merged one is `CarriedCheck`'s to find. Like `CarriedCheck`, it reads the refs as last
      # fetched (`Repository#refresh`).
      class BoardedCheck
        # The remote branches the train boards on, below `refs/remotes/origin/`.
        BRANCHES = "refs/remotes/origin/train/"

        # The state `gh` reports for a pull request that is still open.
        OPEN = "OPEN"

        # The branch name the train gives a boarding, and the commit prefix it carries.
        NAME = %r{\Atrain/main-([0-9a-f]+)\z}

        class << self
          # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`; the
          #   command runner when nil. A spec replaces it so no pull request has to exist.
          attr_accessor :runner
        end

        # @param checkout [String] a directory inside the repository
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @param landed [String] the full commit a run landed
        # @return [String, nil] why a train pull request holds the commit, nil when none does
        def by(landed)
          found = branches.find { |name, boarded| boarded && ancestor?(landed, boarded) && open?(name) }
          found && "is boarded on #{found.first}, whose pull request is open"
        end

        private

        # @return [Array<Array(String, String)>] each remote train branch and the commit it names
        def branches
          done = @git.capture("for-each-ref", "--format=%(refname:strip=3)", BRANCHES, chdir: @checkout)
          return [] unless done.ok?

          done.out.split("\n").map { |name| [name, commit_named(name[NAME, 1])] }
        end

        def commit_named(abbrev)
          return unless abbrev

          done = @git.capture("rev-parse", "--verify", "--quiet", "#{abbrev}^{commit}", chdir: @checkout)
          done.ok? ? done.out.strip : nil
        end

        def ancestor?(sha, ref) = @git.capture("merge-base", "--is-ancestor", sha, ref, chdir: @checkout).ok?

        def open?(branch)
          ok, output = runner.call(["gh", "pr", "view", branch, "--json", "state", "--jq", ".state"], chdir: @checkout)
          ok && output.to_s.strip == OPEN
        end

        def runner = self.class.runner || CommandRunner.new
      end
    end
  end
end
