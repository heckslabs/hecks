module Hecks
  module ValidationRules

    # Hecks::ValidationRules::WorldGoals
    #
    # Validation rules activated by the +world_goals+ DSL keyword. Each rule
    # checks a specific ethical or governance concern (transparency, consent,
    # privacy, security) and only fires when its goal is declared on the domain.
    #
    # Rules are autoloaded and self-register via +Hecks.register_validation_rule+.
    #
    #   Hecks.domain "Health" do
    #     world_goals :transparency, :consent, :privacy, :security
    #     # ... aggregates ...
    #   end
    #
    module WorldGoals
      autoload :Transparency, "hecks/validation_rules/world_goals/transparency"
      autoload :Consent,      "hecks/validation_rules/world_goals/consent"
      autoload :Privacy,      "hecks/validation_rules/world_goals/privacy"
      autoload :Security,     "hecks/validation_rules/world_goals/security"
    end
  end
end
