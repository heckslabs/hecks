# frozen_string_literal: true

module Hecks
  module Tools
    module Lanes
      # The ruleset GitHub is given for a guarded lane.
      module Ruleset
        # What a guarded lane forbids: deleting it, rewinding it, and updating it by anyone the
        # ruleset does not let past.
        RULES = [{ "type" => "deletion" }, { "type" => "non_fast_forward" }, { "type" => "update" }].freeze

        module_function

        # @param lane [Hash{String => String}] a guarded `Lane` row
        # @return [Hash] the ruleset GitHub is given for it
        def build(lane)
          { "name" => "lane-#{lane["name"]}", "target" => "branch", "enforcement" => "active",
            "conditions" => { "ref_name" => { "include" => ["refs/heads/#{lane["name"]}"], "exclude" => [] } },
            "bypass_actors" => bypass(lane), "rules" => RULES }
        end

        # @param lane [Hash{String => String}] a `Lane` row
        # @return [Array<Hash>] who may push past the ruleset: the promotion app, or nobody
        def bypass(lane)
          return [] unless lane["pushers"] == "promotion"

          [{ "actor_id" => Lanes::PROMOTION_APP_ID, "actor_type" => "Integration", "bypass_mode" => "always" }]
        end
      end
    end
  end
end
