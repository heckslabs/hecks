# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"
require "hecks/hecks/adapters/area_overlap"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/dispatching/effective_area"

module Hecks
  module Adapters
    class GitLanding
      # The started Work items that hold ground a branch changes. A branch is landed for its own
      # Work
      # work item, the one keyed by the branch name, so that work item is never a rival; a landing
      # with no work item
      # has none to clash with.
      #
      # A rival holds the files its own branch has committed once it has commits, the same ground
      # {Dispatching::EffectiveArea} gives the fill, read now and not as of the last fill. Files it
      # has edited but not committed are not seen, so they clash at that work item's own landing.
      class Rivals
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param registry [Runtime::Registry, nil] where the Work items are read from
        def initialize(git, checkout, registry)
          @git = git
          @checkout = checkout
          @registry = registry
        end

        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String, nil] the refusal naming the work item and the files, nil when none clash
        def refusal(branch, onto)
          files = changed(branch, onto)
          reader = Dispatching::EffectiveArea.new(@checkout, onto: onto)
          StartedWork.items(@registry).each do |item|
            next if item[:key] == branch

            held = item.merge(area: held_area(reader, item))
            clash = files.select { |file| claims?(held, file) }
            return wording(branch, held, clash) unless clash.empty?
          end
          nil
        end

        private

        Held = Struct.new(:key, :area)

        def held_area(reader, item) = reader.call(Held.new(item[:key], item[:area]))

        def claims?(item, file)
          item[:area].any? { |area| AreaOverlap.overlap?(area, file, root: @checkout, file: true) }
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
