ENV["RAILS_ENV"] = "test"

require_relative "fixture_app/config/environment"
require "rspec/rails"
require "hecks/rails/rspec"

# Helpers the request specs share: Governance grants, a customer, and a fresh identity per example.
#
# The domain boots once, in the Railtie, before the app's autoloader is set up; it is not booted
# again here, because a bluebook's bare `Customer` would then autoload the app's own `Customer`
# model. Each example names its own records instead, so none sees another's.
module FixtureAppHelpers
  # Answers a reference no other example in this run has used.
  #
  # @param prefix [String] what the reference starts with
  # @return [String] the prefix and a number unique to this run
  def fresh(prefix)
    @fresh_counter = (FixtureAppHelpers.instance_variable_get(:@counter) || 0) + 1
    FixtureAppHelpers.instance_variable_set(:@counter, @fresh_counter)
    "#{prefix}#{@fresh_counter}"
  end

  # Grants an actor a role through the domain's Governance chapter, as its first administrator.
  #
  # @param actor_id [String] who is granted the role
  # @param role [String] the role
  # @return [void]
  def grant(actor_id, role)
    facts = { actor_id: actor_id, role_name: role, scope: "bank", starts_at: "2026-01-01T00:00:00Z" }
    Hecks.as_caller(role: "Governance administrator") do
      Hecks::Rails.domain.dispatcher.dispatch("Governance::RoleAssignment.Assign", with: facts)
    end
  end

  # Registers an active customer.
  #
  # @param reference [String] the customer's reference
  # @return [Customer] the customer
  def register_customer(reference)
    Customer.register!(reference: { value: reference }, name: { given: "Ada", family: "Clerk" },
                       email: { address: "ada@example.com" })
  end
end

RSpec.configure do |config|
  config.include FixtureAppHelpers
  config.disable_monkey_patching!
end
