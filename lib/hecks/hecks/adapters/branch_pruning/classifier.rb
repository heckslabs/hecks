# frozen_string_literal: true

require_relative "../branch_work_names"
require_relative "verdict"
require_relative "mirrors"

module Hecks
  module Adapters
    class BranchPruning
      # Judges one local branch by the rules, first match wins: a protected or held branch stays;
      # one whose every commit `main` has by patch is deleted; a mirror goes once its source is
      # gone; a branch of a done item goes only when that item's landed commits are all in `main`;
      # an open item keeps it (a planned one with no session is named for re-planning); a branch
      # no item names is filed as work and kept. A commit `main` lacks is never lost to a guess.
      class Classifier
        PROTECTED = %w[main stable edge].freeze
        RECUT_SUFFIX = /-[vr]\d+\z/

        # @param reading [Reading] what the repository says
        # @param items [Hash{String => String}] each work item's key and status
        # @param landed [#call] given a key, the commits its landings name
        def initialize(reading, items:, landed:)
          @reading = reading
          @items = items
          @landed = landed
          @held = reading.held
          @branches = reading.branches
        end

        # @param branch [String] a local branch
        # @return [Verdict] the judgment, naming the tip it was made at
        def call(branch)
          tip = @reading.tip(branch)
          action, reason = decide(branch)
          Verdict.new(branch, action, reason, tip, (filing(branch) if action == :file))
        end

        private

        def decide(branch)
          return [:keep, "protected or held by a worktree"] if PROTECTED.include?(branch) || @held.include?(branch)
          return [:delete, "every commit is patch-equivalent in main"] if @reading.ahead(branch).empty?

          mirror(branch) || item(branch)
        end

        def mirror(branch)
          source = Mirrors.source(branch)
          return unless source

          if @branches.include?(source)
            [:keep,
             "mirror of #{source}, which is still a branch"]
          else
            [:delete,
             "mirror of #{source}, which is gone"]
          end
        end

        def item(branch)
          key = names(branch).find { |name| @items.key?(name) }
          return [:file, "no work item names it"] unless key

          open_or_done(key)
        end

        # A branch re-cut for a landed item carries `-v2` or `-r2` after the item's key.
        def names(branch)
          named = BranchWorkNames.of(branch, @items.keys)
          (named + named.map { |name| name.sub(RECUT_SUFFIX, "") }).uniq
        end

        def open_or_done(key)
          case @items[key]
          when "done" then done(key)
          when "planned" then [:replan, "item #{key} is planned and nothing holds it"]
          else [:keep, "item #{key} is open"]
          end
        end

        def done(key)
          return [:delete, "its item #{key} landed in main"] if proven?(key)

          [:keep, "item #{key} is done but its landing is not in main"]
        end

        def proven?(key)
          shas = Array(@landed.call(key))
          !shas.empty? && shas.all? { |sha| @reading.on_main?(sha) }
        end

        def filing(branch)
          { title:  "absorb or drop #{branch}",
            detail: ["commits main lacks:", *@reading.commits(branch), "diffstat: #{@reading.diffstat(branch)}"].join("\n") }
        end
      end
    end
  end
end
