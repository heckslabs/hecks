# frozen_string_literal: true

require_relative "git"
require_relative "git_worktrees"
require_relative "branch_pruning/reading"
require_relative "branch_pruning/classifier"
require_relative "branch_pruning/deleting"

module Hecks
  module Adapters
    # The `Pruning` port's adapter: sorts every local branch into one of five outcomes and, when
    # asked, acts on the safe ones. A branch whose commits `main` has (by patch) is deleted; so is
    # a branch of a done item whose landed commits are all in `main`, and an early-CI mirror whose
    # source branch is gone. A branch with open work stays, and one no work item names is filed as
    # work ("absorb or drop <branch>") and never landed. A branch a worktree holds stays.
    #
    # It reads work items and landings through its arguments, so no bluebook is read here, and it
    # never pushes. Only local branches are looked at; a remote `ci/` mirror stays.
    class BranchPruning
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with.
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @git = Git.new
      end

      # Judges every local branch and changes nothing.
      #
      # @param held [Hash] `checkout:` any directory in the repository; `items:` `{key => status}`;
      #   `landed:` a callable from a work item key to the commits its landings name
      # @return [Hash{Symbol => Object}] `verdicts:` a `Verdict` per branch, `report:` one line each
      def survey(**held)
        verdicts = judge(held).first
        { verdicts: verdicts, report: { value: report(verdicts) } }
      end

      # Surveys, then deletes the branches judged deletable and files work for the unlanded ones
      # that no work item names.
      #
      # @param held [Hash] what `survey` takes, plus `filer:` (a callable given `title:`
      #   and `detail:`) and `filed:` (the titles already filed)
      # @return [Hash{Symbol => Object}] `verdicts:` and `report:` with a line per action taken
      def prune(**held)
        verdicts, classifier = judge(held)
        deleter = Deleting.new(@git, @checkout, classifier)
        acts = verdicts.filter_map { |verdict| act(verdict, deleter, held) }
        { verdicts: verdicts, report: { value: acts.empty? ? "nothing to prune" : acts.join("\n") } }
      end

      private

      def judge(held)
        settle(held)
        reading = Reading.new(@git, @checkout)
        classifier = Classifier.new(reading, items: held.fetch(:items, {}), landed: held.fetch(:landed, ->(_key) { [] }))
        [reading.branches.map { |branch| classifier.call(branch) }, classifier]
      end

      def report(verdicts) = verdicts.map(&:line).join("\n")

      def act(verdict, deleter, held)
        case verdict.action
        when :delete then deleter.call(verdict)
        when :file then file(verdict, held)
        end
      end

      def file(verdict, held)
        filer = held[:filer]
        return unless filer && !Array(held[:filed]).include?(verdict.filing[:title])

        filer.call(**verdict.filing)
        "filed #{verdict.filing[:title]}"
      end
    end
  end
end
