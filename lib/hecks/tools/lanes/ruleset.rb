# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../../quality_control/adapters/github_checks"

module Hecks
  module Tools
    module Lanes
      # The ruleset GitHub is given for a guarded lane.
      #
      # A guarded lane cannot be deleted or rewound, and a `green` lane takes only a commit on
      # which every `RequiredCheck` of the Vocabulary chapter has already passed. No actor is let
      # past it: a push of a commit that passed is how a promotion moves the lane, and the GitHub
      # Actions app cannot be named as a bypass actor.
      module Ruleset
        # The GitHub Actions app. A required check counts only when this app reported it, so no
        # other app, token or person can post a passing check of the same name against a commit.
        GITHUB_ACTIONS_APP_ID = Hecks::Adapters::GithubChecks::GITHUB_ACTIONS_APP_ID

        # What every guarded lane forbids: deleting it and rewinding it.
        FIXED = [{ "type" => "deletion" }, { "type" => "non_fast_forward" }].freeze

        module_function

        # @param lane [Hash{String => String}] a guarded `Lane` row
        # @return [Hash] the ruleset GitHub is given for it
        def build(lane)
          { "name" => "lane-#{lane["name"]}", "target" => "branch", "enforcement" => "active",
            "conditions" => { "ref_name" => { "include" => ["refs/heads/#{lane["name"]}"], "exclude" => [] } },
            "bypass_actors" => [], "rules" => rules(lane) }
        end

        # @param lane [Hash{String => String}] a `Lane` row
        # @return [Array<Hash>] the rules: the fixed ones, and the required checks of a `green` lane
        def rules(lane)
          lane["pushers"] == "green" ? [*FIXED, required_checks] : FIXED
        end

        # @return [Hash] the rule that a pushed commit has already passed every `RequiredCheck`
        def required_checks
          contexts = Hecks::Vocabulary.rows("RequiredCheck").map do |check|
            { "context" => check["name"], "integration_id" => GITHUB_ACTIONS_APP_ID }
          end
          { "type"       => "required_status_checks",
            "parameters" => { "strict_required_status_checks_policy" => false, "do_not_enforce_on_create" => false,
                              "required_status_checks" => contexts } }
        end
      end
    end
  end
end
