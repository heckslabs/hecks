module Hecks
  module ValidationRules

    # Hecks::ValidationRules::WorldConcerns
    #
    # Validation rules activated by the +world_concerns+ DSL keyword. Each rule
    # checks a specific ethical or governance concern (transparency, consent,
    # privacy, security) and only fires when its concern is declared on the domain.
    #
    # Rules are autoloaded and self-register via +Hecks.register_validation_rule+.
    #
    #   Hecks.domain "Health" do
    #     world_concerns :transparency, :consent, :privacy, :security
    #     # ... aggregates ...
    #   end
    #
    module WorldConcerns
      autoload :Transparency, "hecks/validation_rules/world_concerns/transparency"
      autoload :Consent,      "hecks/validation_rules/world_concerns/consent"
      autoload :Privacy,      "hecks/validation_rules/world_concerns/privacy"
      autoload :Security,     "hecks/validation_rules/world_concerns/security"
    end
  end
end
