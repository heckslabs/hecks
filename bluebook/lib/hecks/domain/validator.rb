module Hecks
  # Hecks::Validator
  #
  # Validates a domain model for DDD consistency. Runs all registered
  # validation rules and collects error messages. Each rule is a class
  # under ValidationRules:: that takes a domain and returns errors.
  #
  # Rules enforced:
  # - UniqueAggregateNames: no duplicate aggregate names
  # - NameCollisions: aggregate and value object names must not collide
  # - CommandNaming: command names should be verb phrases
  # - ReservedNames: warns about Ruby/system reserved attribute names
  # - ValidReferences: references must target existing aggregate roots
  # - NoBidirectionalReferences: no two aggregates referencing each other
  # - NoSelfReferences: aggregates must not reference themselves
  # - NoValueObjectReferences: value objects must not contain references
  # - AggregatesHaveCommands: every aggregate must have at least one command
  # - CommandsHaveAttributes: structural check on command attributes
  # - ValidPolicyEvents: policy events must match existing events
  # - ValidPolicyTriggers: policy triggers must name existing commands
  #
  #   validator = Validator.new(domain)
  #   validator.valid?   # => true/false
  #   validator.errors   # => ["Order references unknown aggregate: Widget"]
  #
  class Validator
    # Trigger autoloading of all validation rule modules so each rule
    # registers itself with Hecks.register_validation_rule.
    [ValidationRules::Naming, ValidationRules::References, ValidationRules::Structure, ValidationRules::WorldGoals].each do |mod|
      mod.constants.each { |c| mod.const_get(c) }
    end

    # @return [Array<String>] validation error messages (populated after #valid? is called)
    attr_reader :errors

    # @return [Array<String>] non-blocking warnings (populated after #valid? is called)
    attr_reader :warnings

    # @param domain [Hecks::DomainModel::Domain] the domain to validate
    def initialize(domain)
      @domain = domain
      @errors = []
      @warnings = []
    end

    # Run all validation rules and return whether the domain is valid.
    # Populates #errors and #warnings with messages from rules.
    #
    # @return [Boolean] true if no validation errors were found
    def valid?
      rules = Hecks.validation_rules
      @errors = rules.flat_map { |rule| rule.new(@domain).errors }
      @warnings = rules.flat_map { |rule|
        r = rule.new(@domain)
        r.respond_to?(:warnings) ? r.warnings : []
      }
      @errors.empty?
    end
  end
end
