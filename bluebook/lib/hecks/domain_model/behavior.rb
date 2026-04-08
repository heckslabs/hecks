module Hecks
  module BluebookModel

    # Hecks::BluebookModel::Behavior
    #
    # Namespace for domain behavior representations: commands (intent to change
    # state), events (records of what happened), policies (reactive rules and
    # guards), queries (named lookups), specifications (reusable predicates),
    # workflows (multi-step orchestrations), services (cross-aggregate orchestration),
    # read models (event-driven projections), and event subscribers (arbitrary
    # event handlers).
    #
    # Part of the BluebookModel IR layer. Each child class is a plain data object
    # (intermediate representation) built by the DSL builders and consumed by
    # generators to produce runtime domain code.
    #
    # == Child classes
    #
    #   Behavior::Command         # intent to change aggregate state
    #   Behavior::Condition       # pre/postcondition assertion on a command
    #   Behavior::BluebookEvent     # record that something happened
    #   Behavior::EventSubscriber # arbitrary code block fired on an event
    #   Behavior::Policy          # reactive rule (event->command) or guard block
    #   Behavior::Query           # named, reusable lookup
    #   Behavior::ReadModel       # event-driven denormalized projection
    #   Behavior::Service         # cross-aggregate orchestration
    #   Behavior::Specification   # named, reusable boolean predicate
    #   Behavior::Workflow        # conditional multi-step command orchestration
    #
    module Behavior
      autoload :Command,     "hecks/domain_model/behavior/command"
      autoload :Condition,   "hecks/domain_model/behavior/condition"
      autoload :BluebookEvent, "hecks/domain_model/behavior/domain_event"
      autoload :Policy,      "hecks/domain_model/behavior/policy"
      autoload :Query,            "hecks/domain_model/behavior/query"
      autoload :EventSubscriber, "hecks/domain_model/behavior/event_subscriber"
      autoload :Specification,   "hecks/domain_model/behavior/specification"
      autoload :Service,         "hecks/domain_model/behavior/service"
      autoload :ReadModel,       "hecks/domain_model/behavior/read_model"
      autoload :Workflow,        "hecks/domain_model/behavior/workflow"
      autoload :CommandStep,    "hecks/domain_model/behavior/workflow_step"
      autoload :BranchStep,     "hecks/domain_model/behavior/workflow_step"
      autoload :ScheduledStep,  "hecks/domain_model/behavior/workflow_step"
      autoload :Saga,           "hecks/domain_model/behavior/saga"
      autoload :SagaStep,       "hecks/domain_model/behavior/saga_step"
    end
  end
end
