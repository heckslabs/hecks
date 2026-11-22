# frozen_string_literal: true

require_relative "../git"

module Hecks
  module Adapters
    class MainIntegration
      # Brings local main level with origin/main when a train merged there: origin/main is merged
      # into main, so a tip made on the old base sits on a main that holds the train's merge commit
      # and boards with no conflict. Main is only ever moved forward (a fast-forward or a merge
      # commit, nothing when level), never rewritten. A merge that conflicts is abandoned and
      # leaves main where it was.
      class Leveling
        REMOTE = "origin/main"

        # @param checkout [String] the checkout whose branch is main
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @return [String, nil] why origin/main could not be merged into main (the files in
        #   conflict); nil when main is level, was brought level, or is not checked out here
        def call
          return unless on_main? && clean?

          merged = merge
          merged.ok? ? nil : abandon
        end

        private

        def merge = @git.capture(*identity, "merge", "--no-edit", REMOTE, chdir: @checkout)

        def abandon
          files = @git.capture("diff", "--name-only", "--diff-filter=U", chdir: @checkout).out.split
          @git.capture("merge", "--abort", chdir: @checkout)
          "cannot merge #{REMOTE} into main: conflicts in #{files.join(", ")}; main is unchanged"
        end

        def on_main? = out("symbolic-ref", "--short", "HEAD").strip == "main"

        def clean? = blank?(out("status", "--porcelain", "--untracked-files=no"))

        def out(*) = @git.capture(*, chdir: @checkout).out

        def blank?(text) = text.strip.empty?

        # A committer for the merge commit, when git knows no one.
        def identity
          return [] unless blank?(out("config", "user.email"))

          ["-c", "user.name=Hecks", "-c", "user.email=hecks@localhost"]
        end
      end
    end
  end
end
