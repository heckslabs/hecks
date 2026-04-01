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

    WORLD_GOALS_MODULE = ValidationRules::WorldGoals

    # @return [Array<String>] validation error messages (populated after #valid? is called)
    attr_reader :errors

    # @return [Array<String>] non-blocking warnings (populated after #valid? is called)
    attr_reader :warnings

    # @return [Array<String>] world-goals-only errors (populated after #valid? is called)
    attr_reader :world_goals_errors

    # @param domain [Hecks::DomainModel::Domain] the domain to validate
    def initialize(domain)
      @domain = domain
      @errors = []
      @warnings = []
      @world_goals_errors = []
    end

    # Run all validation rules and return whether the domain is valid.
    # Populates #errors, #warnings, and #world_goals_errors.
    #
    # @return [Boolean] true if no validation errors were found
    def valid?
      rules = Hecks.validation_rules
      wg_rules, _other_rules = rules.partition { |r| world_goal_rule?(r) }

      @errors = rules.flat_map { |rule| rule.new(@domain).errors }
      @world_goals_errors = wg_rules.flat_map { |rule| rule.new(@domain).errors }
      @warnings = rules.flat_map { |rule|
        r = rule.new(@domain)
        r.respond_to?(:warnings) ? r.warnings : []
      }
      @errors.empty?
    end

    # Produce a Mother Earth report summarizing world goals status.
    # Returns nil when no goals are declared.
    #
    # @return [Hash, nil] report with :goals_declared, :violations,
    #   :passing_goals, :failing_goals keys
    def mother_earth_report
      declared = @domain.world_goals
      return nil if declared.empty?

      failing = declared.select { |goal| goal_failing?(goal) }
      {
        goals_declared: declared,
        violations:     @world_goals_errors,
        passing_goals:  declared - failing,
        failing_goals:  failing
      }
    end

    private

    def world_goal_rule?(rule_class)
      rule_class.name&.start_with?(WORLD_GOALS_MODULE.name)
    end

    def goal_failing?(goal)
      label = goal.to_s.capitalize
      @world_goals_errors.any? { |e| e.start_with?("#{label}:") }
    end
  end
end
