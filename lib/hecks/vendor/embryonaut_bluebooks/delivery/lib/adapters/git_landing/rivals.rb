# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"
require_relative "bound_claims"

module Hecks
  module Adapters
    class GitLanding
      # The claims that hold ground a branch changes, asked of the `Claims` port ({BoundClaims}). A
      # branch is landed for its own claim, the one keyed by the branch name, so that claim is never
      # a rival; a project that binds nothing to the port has none to clash with.
      class Rivals
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param registry [Runtime::Registry, nil] where the adapter bound to `Claims` is found
        def initialize(git, checkout, registry)
          @git = git
          @checkout = checkout
          @claims = BoundClaims.new(registry)
        end

        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String, nil] the refusal naming the claim and the files, nil when none clash
        def refusal(branch, onto)
          files = changed(branch, onto)
          @claims.items.each do |item|
            next if item[:key] == branch

            clash = files.select { |file| claims?(item, file) }
            return wording(branch, item, clash) unless clash.empty?
          end
          nil
        end

        private

        def claims?(item, file)
          item[:area].any? { |area| @claims.overlap?(area, file, @checkout) }
        end

        def wording(branch, item, clash)
          "#{branch} changes #{clash.join(", ")}, in the area of #{item[:key]} (#{item[:area].join(", ")})"
        end

        def changed(branch, onto)
          result = @git.capture("diff", "--no-renames", "--name-only", "-z", "#{ref(onto)}...#{ref(branch)}",
                                chdir: @checkout)
          raise ConsoleCapture::Failure, "git diff failed in #{@checkout}: #{result.err.strip}" unless result.ok?

          result.out.split("\0").reject(&:empty?)
        end
      end
    end
  end
end
