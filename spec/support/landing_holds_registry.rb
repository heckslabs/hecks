# frozen_string_literal: true

require "hecks/hecks/adapters/landing_holding"

# A registry that binds what Hecks binds to delivery's `Holds` port, `LandingHolding`, and nothing
# else, so a landing spec meets the red flag and the boarding hold without booting Hecks.
module LandingHoldsRegistry
  # One bound adapter, as a booted registry lists it.
  Bound = Struct.new(:name, :port)

  # A registry with the adapter bound, no world, so a hold lasts its default window, and no
  # bluebook, so no started Work item overlaps a landing.
  Registry = Struct.new(:adapters) do
    # @return [nil] no world: the adapter falls back to its defaults
    def world(_name) = nil

    # @return [nil] no bluebook is booted
    def bluebook(_name) = nil
  end

  module_function

  # @return [Registry] a registry binding `LandingHolding` to `Holds`
  def landing_holds_registry = Registry.new({ "LandingHolding" => Bound.new("LandingHolding", "Holds") })
end
