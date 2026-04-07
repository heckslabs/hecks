module Hecks
  module Generators
    # Hecks::Generators::Domain
    #
    # Parent module for domain artifact generators. Autoloads generators for
    # aggregates, value objects, commands, events, policies, query classes,
    # and query object modules. Part of the Generators layer, consumed by
    # DomainGemGenerator and InMemoryLoader to produce domain code.
    #
    # Each generator follows the same pattern: initialize with a domain model
    # object and a +domain_module+ name, then call +#generate+ to produce a
    # Ruby source string. The generated code is either written to disk (gem
    # generation) or evaluated in-memory (playground/session).
    #
    # == Available Generators
    #
    # - +AggregateGenerator+ -- aggregate root classes with Hecks::Model
    # - +ValueObjectGenerator+ -- frozen, immutable value objects with value equality
    # - +EntityGenerator+ -- mutable sub-entities with identity-based equality
    # - +CommandGenerator+ -- CQRS command classes (create/update) with event emission
    # - +EventGenerator+ -- frozen domain event classes with timestamps
    # - +PolicyGenerator+ -- guard and reactive policy classes
    # - +QueryGenerator+ -- query classes with +call+ methods
    # - +QueryObjectGenerator+ -- query modules with +by_<attr>+ finder methods
    # - +SubscriberGenerator+ -- event subscriber classes
    # - +SpecificationGenerator+ -- specification pattern classes with +satisfied_by?+
    # - +LifecycleGenerator+ -- state machine classes with transitions and predicates
    # - +ServiceGenerator+ -- domain service classes orchestrating cross-aggregate logic
    # - +WorkflowGenerator+ -- multi-step workflow classes with conditional branching
    # - +ViewGenerator+ -- CQRS read model (view) classes with event projections
    #
    # == Usage
    #
    #   Domain::AggregateGenerator.new(agg, domain_module: "PizzasDomain").generate
    #
    module Domain
      autoload :AggregateGenerator,    "hecks/generators/domain/aggregate_generator"
      autoload :ValueObjectGenerator,  "hecks/generators/domain/value_object_generator"
      autoload :EntityGenerator,       "hecks/generators/domain/entity_generator"
      autoload :CommandGenerator,      "hecks/generators/domain/command_generator"
      autoload :EventGenerator,        "hecks/generators/domain/event_generator"
      autoload :PolicyGenerator,       "hecks/generators/domain/policy_generator"
      autoload :QueryGenerator,        "hecks/generators/domain/query_generator"
      autoload :QueryObjectGenerator,  "hecks/generators/domain/query_object_generator"
      autoload :SubscriberGenerator,      "hecks/generators/domain/subscriber_generator"
      autoload :SpecificationGenerator,  "hecks/generators/domain/specification_generator"
      autoload :LifecycleGenerator,     "hecks/generators/domain/lifecycle_generator"
      autoload :ServiceGenerator,       "hecks/generators/domain/service_generator"
      autoload :WorkflowGenerator,      "hecks/generators/domain/workflow_generator"
      autoload :ViewGenerator,          "hecks/generators/domain/view_generator"
    end
  end
end
