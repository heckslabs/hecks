module Hecks
  module BluebookModel

    # Hecks::BluebookModel::Structure
    #
    # Namespace for the structural building blocks of a domain model: domains,
    # aggregates, value objects, attributes, validations, invariants, scopes,
    # ports, read models, external systems, and actors.
    #
    # Part of the BluebookModel IR layer. Each child class is an intermediate
    # representation built by the DSL and consumed by generators.
    #
    # == Structural Hierarchy
    #
    # The classes in this namespace form a tree:
    #
    #   Structure::Domain              # root container holding aggregates and domain-level policies
    #     Structure::Aggregate         # DDD aggregate with commands, events, lifecycle, etc.
    #       Structure::Attribute       # typed field on any structure (aggregate, value object, entity, command, event)
    #       Structure::ValueObject     # immutable object defined by its attributes (no identity)
    #       Structure::Entity          # mutable sub-entity with identity (UUID)
    #       Structure::Validation      # attribute-level validation rule (presence, type, uniqueness)
    #       Structure::Invariant       # business rule that must always hold true
    #       Structure::Scope           # named query scope with static or callable conditions
    #       Structure::GateDefinition  # access-control port defining allowed methods per role
    #       Structure::Lifecycle       # state machine definition with transitions tied to commands
    #     Structure::ReadModel         # data view needed before issuing a command (Event Storming artifact)
    #     Structure::ExternalSystem    # third-party system outside the domain boundary
    #     Structure::Actor             # user role or persona that issues commands
    #
    # == Usage
    #
    # These classes are not instantiated directly by application code. They are
    # built by the DSL layer (BluebookBuilder, AggregateBuilder, etc.) when parsing
    # a domain definition, and then consumed by generators, the runtime, and
    # visualization tools.
    #
    #   # Typical flow:
    #   domain = Hecks::DSL::BluebookBuilder.new("Pizzas") { ... }.build
    #   domain.class  # => Hecks::BluebookModel::Structure::Domain
    #   domain.aggregates.first.class  # => Hecks::BluebookModel::Structure::Aggregate
    #
    module Structure
      autoload :Domain,         "hecks/domain_model/structure/domain"
      autoload :Aggregate,      "hecks/domain_model/structure/aggregate"
      autoload :ValueObject,    "hecks/domain_model/structure/value_object"
      autoload :Entity,         "hecks/domain_model/structure/entity"
      autoload :Attribute,      "hecks/domain_model/structure/attribute"
      autoload :Validation,     "hecks/domain_model/structure/validation"
      autoload :Invariant,      "hecks/domain_model/structure/invariant"
      autoload :Scope,          "hecks/domain_model/structure/scope"
      # GateDefinition lives in hecksagon
      autoload :ReadModel,      "hecks/domain_model/structure/read_model"
      autoload :ExternalSystem, "hecks/domain_model/structure/external_system"
      autoload :Actor,          "hecks/domain_model/structure/actor"
      autoload :Lifecycle,        "hecks/domain_model/structure/lifecycle"
      autoload :StateTransition, "hecks/domain_model/structure/state_transition"
      autoload :Reference,         "hecks/domain_model/structure/reference"
      autoload :ComputedAttribute, "hecks/domain_model/structure/computed_attribute"
      autoload :Paragraph,         "hecks/domain_model/structure/paragraph"
      autoload :BluebookStructure, "hecks/domain_model/structure/bluebook_structure"
    end
  end
end
