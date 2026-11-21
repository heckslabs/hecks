# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"
require_relative "bound_claims"

module Hecks
  module Adapters
    class GitLanding
      # The lines a branch takes out of files its own item does not hold, asked of the `Claims`
      # port ({BoundClaims}). A branch whose rebase kept a stale copy of other landed work shows
      # as deletions in files outside its area; a branch that only adds outside its area is let
      # through, and so is a branch whose item names the file in its area. A branch with no claim,
      # or a claim with no area, has no declared ground to judge against and is not refused.
      # Generated files and golden fixtures are rewritten by regeneration and are not judged.
      class Strays
        include GitWorktrees

        # A banner that marks a file as generated.
        GENERATED = /generated.*(do not edit|by )/i

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
        # @return [String, nil] the refusal naming each file and its lines, nil when none stray
        def refusal(branch, onto)
          area = own_area(branch)
          return if area.empty?

          strays = removals(branch, onto).reject { |file, _| held?(area, file) || generated?(branch, file) }
          wording(branch, area, strays) unless strays.empty?
        end

        private

        def own_area(branch) = Array(@claims.items.find { |item| item[:key] == branch }&.dig(:area))

        def held?(area, file) = area.any? { |one| @claims.overlap?(one, file, @checkout) }

        def generated?(branch, file)
          return true if file.include?("_golden/")

          head = @git.capture("show", "#{ref(branch)}:#{file}", chdir: @checkout)
          head.ok? && banner?(head.out)
        end

        def banner?(text) = text.lines.first(5).any? { |line| line.match?(GENERATED) }

        def wording(branch, area, strays)
          list = strays.map { |file, count| "#{file} (#{count} lines)" }.join(", ")
          "#{branch} deletes or rewrites lines outside its area (#{area.join(", ")}): #{list}"
        end

        # Each file the branch removes lines from, with how many.
        def removals(branch, onto)
          result = @git.capture("diff", "--no-renames", "--numstat", "-z", "#{ref(onto)}...#{ref(branch)}", chdir: @checkout)
          raise ConsoleCapture::Failure, "git diff failed in #{@checkout}: #{result.err.strip}" unless result.ok?

          rows(result.out).to_h
        end

        def rows(out) = out.split("\0").filter_map { |row| count(row) }

        def count(row)
          added, deleted, file = row.split("\t", 3)
          [file, deleted.to_i] if file && added != "-" && deleted.to_i.positive?
        end
      end
    end
  end
end
