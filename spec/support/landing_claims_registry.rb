# frozen_string_literal: true

require "hecks/hecks/adapters/landing_claims"
require_relative "landing_holds_registry"

# A registry that binds what Hecks binds to delivery's `Claims` port, `LandingClaims`, and
# nothing else, so a landing spec meets the started Work items without booting Hecks.
module LandingClaimsRegistry
  module_function

  # @return [LandingHoldsRegistry::Registry] a registry binding `LandingClaims` to `Claims`
  def landing_claims_registry
    bound = LandingHoldsRegistry::Bound.new("LandingClaims", "Claims")
    LandingHoldsRegistry::Registry.new({ "LandingClaims" => bound })
  end
end
