# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../tools"
require_relative "../hecks/adapters/github_rulesets"

module Hecks
  module Tools
    # Projects the `Lane` rows of the Vocabulary chapter into what GitHub is told about them: a
    # ruleset for each guarded lane (`.github/rulesets/<lane>.json`) and the workflow that promotes
    # each lane that follows another (`.github/workflows/promote.yml`). The workflow only runs
    # `hecks promotion_run.promote`; the rule that decides a promotion is `PromotionRun.Accept`.
    #
    # Without a flag the files are written. `--check` writes nothing and answers 1 for each file
    # that differs, which is the drift gate. `--live` compares the rulesets GitHub holds with the
    # projection and writes no file; with `--confirm` as well it creates or updates them, the one
    # step that changes GitHub.
    module Lanes
      # Where the projected rulesets and workflows live, relative to the checkout.
      RULESETS = ".github/rulesets"
      WORKFLOW = ".github/workflows/promote.yml"

      # What `pushers` may say: a lane that takes any commit, or one that takes only a commit every
      # `RequiredCheck` has passed.
      PUSHERS = %w[anyone green].freeze

      module_function

      # @param argv [Array<String>] `--check`, `--live`, `--confirm`
      # @param root [String] the checkout
      # @param rulesets [Hecks::Adapters::GithubRulesets, nil] GitHub's rulesets; a spec replaces it
      # @return [Integer] 0, or 1 when `--check` or `--live` finds a difference
      # @raise [SystemExit] when a row is one the projection cannot express
      def main(argv, root: Tools::ROOT, rulesets: nil)
        if argv.include?("--live")
          return Live.new(rulesets || Hecks::Adapters::GithubRulesets.new).run(argv.include?("--confirm"))
        end

        Files.new(root).run(argv.include?("--check"))
      end

      # @param root [String] the checkout
      # @return [Hash{String => String}] each file's absolute path to the text it should hold
      def projection(root) = Files.new(root).projection

      # @param root [String] the checkout
      # @param files [Hash{String => String}] the projection
      # @return [Array<String>] ruleset files that no row of a guarded lane accounts for
      def leftover(root, files) = Files.new(root).leftover(files)

      # @return [Array<Hash{String => String}>] the `Lane` rows
      def lanes = Rows.all

      # @param lane [Hash{String => String}] a guarded `Lane` row
      # @return [Hash] the ruleset GitHub is given for it
      def ruleset(lane) = Ruleset.build(lane)

      # @param promoted [Array<Hash{String => String}>] the lanes that follow another
      # @return [String] the promotion workflow
      def workflow(promoted) = Workflow.text(promoted)
    end
  end
end

require_relative "lanes/rows"
require_relative "lanes/ruleset"
require_relative "lanes/workflow"
require_relative "lanes/files"
require_relative "lanes/live"
