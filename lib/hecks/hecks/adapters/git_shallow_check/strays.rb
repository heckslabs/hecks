# frozen_string_literal: true

require_relative "../started_work"
require_relative "../area_overlap"

module Hecks
  module Adapters
    class GitShallowCheck
      # The lines a branch takes out of files its own Work item does not hold.
      #
      # A branch whose rebase kept a stale copy of other landed work shows as deletions in files
      # outside its area. A branch that only adds outside its area is let through, and so is one
      # whose item names the file in its area. A branch with no started Work item, or one with no
      # area, has no declared ground to judge against and is not refused. Generated files and
      # golden fixtures are rewritten by regeneration and are not judged.
      class Strays
        # A banner that marks a file as generated.
        GENERATED = /generated.*(do not edit|by )/i

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param registry [Runtime::Registry, nil] where the started Work items are read from
        def initialize(git, checkout, registry)
          @git = git
          @checkout = checkout
          @registry = registry
        end

        # @param branch [String] the branch to land
        # @param onto [String] the ref it lands on
        # @return [String, nil] the refusal naming each file and its lines, nil when none stray
        def refusal(branch, onto)
          area = own_area(branch)
          return if area.empty?

          strays = removals(branch, onto).reject { |file, _| held?(area, file) || generated?(branch, file) }
          wording(branch, area, strays) unless strays.empty?
        end

        private

        def own_area(branch) = Array(StartedWork.items(@registry).find { |item| item[:key] == branch }&.dig(:area))

        def held?(area, file) = area.any? { |one| AreaOverlap.overlap?(one, file, root: @checkout, file: true) }

        def generated?(branch, file)
          return true if file.include?("_golden/")

          head = @git.capture("show", "#{branch}:#{file}", chdir: @checkout)
          head.ok? && banner?(head.out)
        end

        def banner?(text) = text.lines.first(5).any? { |line| line.match?(GENERATED) }

        def wording(branch, area, strays)
          list = strays.map { |file, count| "#{file} (#{count} lines)" }.join(", ")
          "#{branch} deletes or rewrites lines outside its area (#{area.join(", ")}): #{list}"
        end

        # Each file the branch removes lines from, with how many.
        def removals(branch, onto)
          result = @git.capture("diff", "--no-renames", "--numstat", "-z", "#{onto}...#{branch}", chdir: @checkout)
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
