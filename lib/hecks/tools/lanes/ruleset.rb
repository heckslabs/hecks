# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../../quality_control/adapters/github_checks"

module Hecks
  module Tools
    module Lanes
      # The ruleset GitHub is given for a guarded lane.
      #
      # A guarded lane cannot be deleted or rewound, and a `green` lane takes only a commit on
      # which every `RequiredCheck` of the Vocabulary bluebook has already passed. No actor is let
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

        # The ruleset for the tag a guarded lane feeds. The tag follows the lane, so it may move
        # forward, which GitHub allows under `non_fast_forward` (a descendant is not a force-push);
        # it cannot be deleted or pointed at an older commit, and no actor is let past it.
        #
        # @param lane [Hash{String => String}] a guarded `Lane` row
        # @return [Hash, nil] the ruleset GitHub is given for the tag, nil when the lane feeds none
        def tag(lane)
          feed = lane["feeds"].to_s
          return if feed.empty?

          { "name" => "tag-#{feed}", "target" => "tag", "enforcement" => "active",
            "conditions" => { "ref_name" => { "include" => ["refs/tags/#{feed}"], "exclude" => [] } },
            "bypass_actors" => [], "rules" => FIXED }
        end

        # How a `queue` lane's merge queue builds and merges. Each entry is tested on top of the
        # lane and every entry ahead of it, up to five at once, and merges only when all its checks
        # pass,
        # so a pull request that is green alone but red beside another never lands. A squash keeps
        # one commit per pull request on the lane.
        MERGE_QUEUE = { "type"       => "merge_queue",
                        "parameters" => { "merge_method" => "SQUASH", "grouping_strategy" => "ALLGREEN",
                                          "max_entries_to_build" => 5, "max_entries_to_merge" => 5,
                                          "min_entries_to_merge" => 1, "min_entries_to_merge_wait_minutes" => 1,
                                          "check_response_timeout_minutes" => 60 } }.freeze

        # A `queue` lane moves only by a merged pull request. No review is required: the checks are
        # the gate, so an agent's pull request can enter the queue as soon as it is opened.
        PULL_REQUEST_PARAMETERS = {
          "required_approving_review_count"   => 0,
          "dismiss_stale_reviews_on_push"     => false,
          "require_code_owner_review"         => false,
          "require_last_push_approval"        => false,
          "required_review_thread_resolution" => false,
          "allowed_merge_methods"             => ["squash"]
        }.freeze
        PULL_REQUEST = { "type" => "pull_request", "parameters" => PULL_REQUEST_PARAMETERS }.freeze

        # @param lane [Hash{String => String}] a `Lane` row
        # @return [Array<Hash>] the rules: the fixed ones; a `green` lane's required checks; and a
        #   `queue` lane's pull request, merge queue and required checks
        def rules(lane)
          case lane["pushers"]
          when "green" then [*FIXED, required_checks]
          when "queue" then [*FIXED, PULL_REQUEST, MERGE_QUEUE, required_checks]
          else FIXED
          end
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
