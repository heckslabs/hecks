# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../../../../quality_control/adapters/github_checks"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # Where every `RequiredCheck` of the Vocabulary chapter stands against one commit.
        #
        # It reports and does not decide: `Accept` holds the rule that a promotion needs every check
        # green. A check that has not finished (or has not started) is told apart from one that
        # failed, so the refusal can say whether to wait or to fix.
        class Gate
          # @param commit [String] the commit to read the checks of
          def initialize(commit)
            @commit = commit
          end

          # @return [Boolean] whether every required check passed
          def green?
            failed.empty? && waiting.empty?
          end

          # @return [String] what keeps the commit from being green: the checks that failed, then
          #   those still to finish; empty when it is green
          def why
            [("failed: #{failed.join(", ")}" unless failed.empty?),
             ("waiting on: #{waiting.join(", ")}" unless waiting.empty?)].compact.join("; ")
          end

          private

          def failed = named(%i[failed])

          def waiting = named(%i[pending missing])

          def named(kinds) = states.select { |_, state| kinds.include?(state) }.keys

          def states
            @states ||= (Promotion.checks || GithubChecks.new).states(commit: @commit, names: names)
          end

          def names = Hecks::Vocabulary.rows("RequiredCheck").map { |check| check["name"] }
        end
      end
    end
  end
end
