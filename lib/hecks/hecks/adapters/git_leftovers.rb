# frozen_string_literal: true

require_relative "delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require_relative "landed_branches"

module Hecks
  module Adapters
    # The `Leftovers` port's adapter: after a push, lists the worktrees of branches that landed and
    # are still there, each with what a retirement would do. It removes nothing, so a session still
    # working in one is never moved; a person or agent retires what the list says is safe.
    #
    # A branch counts only if `Landing` recorded it as landed, so a worktree that was merely opened
    # is never named. What a retirement would do is `GitLanding::Tidy`'s own verdict, so the list
    # and `Landing.retire!` cannot disagree.
    class GitLeftovers
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with; only the registry is kept.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] where the landed `Landing` rows are read
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @git = Git.new
        @registry = registry
      end

      # @param held [Hash] the `SendTrain` record: `checkout` (any directory in the repository)
      # @return [Hash{Symbol => Hash}] `report:` one line per such worktree, or that none is left
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def leftovers(**held)
        settle(held)
        lines = LandedBranches.of(@registry).filter_map { |branch| line(branch) }
        { report: { value: lines.empty? ? "no landed worktree is left" : lines.join("\n") } }
      end

      private

      def line(branch)
        return unless worktree_on(branch)

        "#{branch}: #{GitLanding::Tidy.new(@git, @checkout, branch: branch, onto: "main").verdict}"
      rescue ConsoleCapture::Failure => e
        "#{branch}: could not be checked (#{e.message})"
      end
    end
  end
end
