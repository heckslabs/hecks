# frozen_string_literal: true

# Runs a bluebook's compiled guard or policy condition on a field that is missing, empty or set,
# for the guard specs. Each domain boots once per run, in Memory, from its own directory.
module MissingValueGuards
  MISSING = [nil, { value: nil }].freeze

  # @param dir [String] the domain directory, relative to the repository root
  # @param name [String] the bluebook's name
  # @return [Hecks::Bluebook] the booted bluebook
  def self.bluebook(dir, name)
    @booted ||= {}
    @booted[dir] ||= InMemoryDomain.boot_hecks_in_memory(File.join(InMemoryDomain::ROOT, dir))
    @booted[dir].registry.bluebook(name)
  end

  # @return [Object] the given of `command` whose text includes `phrase`
  def given_of(command, phrase)
    command.givens.find { |rule| rule.canonical.include?(phrase) }
  end

  # @return [Boolean] whether `rule` holds on the aggregate `state`
  def holds?(rule, state)
    Hecks::Bluebook::Expression::Evaluator.call_rule(rule, state)
  end

  # @return [Boolean] whether `policy`'s condition holds on an event's `payload`
  def fires?(policy, payload)
    Hecks::Bluebook::Expression::Evaluator.call_rule(policy.where_rule, {}, payload)
  end
end
