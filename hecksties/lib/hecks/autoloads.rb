# = Hecks Autoloads
#
# Central autoload registry mapping every Hecks module to its source file.
# This is an infrastructure-level file required by +lib/hecks.rb+ to enable
# lazy loading of all framework components.
#
# Autoloads are organized into logical groups:
# - *Mixins* -- Modules included into generated domain classes (+Command+,
#   +Model+, +Query+, +Specification+)
# - *Framework plumbing* -- Core utilities, configuration, CLI, workshop,
#   versioning, and migrations
# - *Domain tools* -- Validator, connections, glossary, visualizer, serializer
# - *ValidationRules* -- Individual validation rule classes for domain linting
# - *BluebookModel* -- Structure and behavior types (aggregates, entities,
#   value objects, commands, events)
# - *DSL* -- Builder classes for the domain definition DSL
# - *Generators* -- Code generators for domain classes, SQL adapters, and
#   infrastructure scaffolding
# - *EventStorm* -- Parsers and builders for importing event storming artifacts
# - *Runtime components* -- Runtime, ports (commands, queries, repository,
#   event bus, queue), workflow executor, and view binding
# - *HTTP* -- Rack-based domain server, RPC server, route builder, and
#   OpenAPI/JSON Schema generators
#
# Connection-specific autoloads (HTTP, MCP, SQL, CLI) live in their respective
# top-level entry points (+hecks_serve+, +hecks_ai+, +hecks_persist+,
# +hecks_cli+).
#
module Hecks
  # Mixins (included into generated aggregate/entity/value object classes)
  autoload :Command,        "hecks/mixins/command"
  autoload :Model,          "hecks/mixins/model"
  autoload :Query,          "hecks/mixins/query"
  autoload :Specification,  "hecks/mixins/specification"

  autoload :Utils,          "hecks/utils"
  autoload :VERSION,        "hecks/version"
  autoload :Configuration,  "hecks/runtime/configuration"
  autoload :CLI,            "hecks_cli/cli"
  autoload :Workshop,      "hecks/workshop"
  autoload :Versioner,      "hecks/domain/versioner"
  autoload :Migrations,     "hecks/domain/migrations"


  # Domain tools
  autoload :Validator,         "hecks/domain/validator"
  autoload :BluebookConnections, "hecks/domain/connections"
  autoload :DomainGlossary,    "hecks/domain/glossary"
  autoload :LlmsGenerator,     "hecks/domain/llms_generator"
  autoload :DomainVisualizer,  "hecks/domain/visualizer"
  autoload :ContextMapGenerator, "hecks/domain/context_map_generator"
  autoload :DslSerializer,     "hecks/domain/dsl_serializer"
  autoload :DomainVersioning,  "hecks/domain_versioning"
  autoload :FlowGenerator,     "hecks/domain/flow_generator"

  # = Hecks::ValidationRules
  #
  # Namespace for individual domain validation rule classes. Each rule
  # implements a +call(domain)+ method that returns an array of warning
  # or error messages. Rules are run by {Hecks::Validator} to lint a
  # domain definition.
  module ValidationRules
    autoload :ValidationMessage, "hecks/validation_rules/validation_message"
    autoload :BaseRule,    "hecks/validation_rules/base_rule"
    autoload :Naming,      "hecks/validation_rules/naming"
    autoload :References,  "hecks/validation_rules/references"
    autoload :Structure,   "hecks/validation_rules/structure"
    autoload :WorldConcerns, "hecks/validation_rules/world_concerns"
  end

  # = Hecks::BluebookModel
  #
  # Namespace for the domain model type system. Contains two sub-namespaces:
  # - +Structure+ -- Structural types: Domain, Aggregate, Entity, ValueObject,
  #   Attribute, ReadModel, Port, DomainService
  # - +Behavior+ -- Behavioral types: Command, Event, Policy, Lifecycle,
  #   Workflow, Guard, Invariant
  module BluebookModel
    autoload :Behavior,                "hecks/domain_model/behavior"
    autoload :Structure,               "hecks/domain_model/structure"
    autoload :Names,                   "hecks/domain_model/names"
    autoload :SubscriberRegistration,  "hecks/domain_model/subscriber_registration"
  end

  # = Hecks::DSL
  #
  # Namespace for the domain definition DSL builder classes. Each builder
  # provides a block-based API for constructing one type of domain model
  # element. Builders are used internally by {Hecks::BluebookBuilderMethods}
  # and by the +Hecks.build+ entry point.
  module DSL
    autoload :AttributeCollector, "hecks/dsl/attribute_collector"
    autoload :BluebookBuilder,      "hecks/dsl/domain_builder"
    autoload :AggregateBuilder,   "hecks/dsl/aggregate_builder"
    autoload :ValueObjectBuilder, "hecks/dsl/value_object_builder"
    autoload :EntityBuilder,      "hecks/dsl/entity_builder"
    autoload :CommandBuilder,     "hecks/dsl/command_builder"
    autoload :PolicyBuilder,       "hecks/dsl/policy_builder"
    autoload :AggregateRebuilder,  "hecks/dsl/aggregate_rebuilder"
    # GateBuilder lives in hecksagon, not bluebook DSL
    autoload :ServiceBuilder,      "hecks/dsl/service_builder"
    autoload :LifecycleBuilder,    "hecks/dsl/lifecycle_builder"
    autoload :ReadModelBuilder,    "hecks/dsl/read_model_builder"
    autoload :WorkflowBuilder,     "hecks/dsl/workflow_builder"
    autoload :BranchBuilder,       "hecks/dsl/workflow_builder"
    autoload :StepCollector,       "hecks/dsl/workflow_builder"
  end

  # = Hecks::Generators
  #
  # Namespace for code generators. Generators produce Ruby source files,
  # SQL schemas, and infrastructure scaffolding from domain definitions.
  # - +Domain+ -- Generates aggregate, entity, value object, and command classes
  # - +SQL+ -- Generates Sequel-based repository adapters and migration files
  # - +Infrastructure+ -- Generates gemspec, spec_helper, and project scaffolding
  module Generators
    autoload :Domain,         "hecks/generators/domain"
    autoload :SQL,            "hecks_persist"
    autoload :Infrastructure, "hecks/generators/infrastructure"
  end

  require "hecks/generators/registry"

  # = Hecks::EventStorm
  #
  # Namespace for event storming import tools. Parses event storm artifacts
  # (from text or YAML) and converts them into Hecks domain definitions.
  # - +Parser+ -- Parses structured text event storm notation
  # - +YamlParser+ -- Parses YAML-formatted event storm files
  # - +BluebookBuilder+ -- Converts parsed event storm data into domain objects
  # - +DslGenerator+ -- Generates Hecks DSL source code from parsed data
  # - +Result+ -- Value object wrapping the parse result
  module EventStorm
    autoload :Parser,        "hecks/event_storm/parser"
    autoload :YamlParser,    "hecks/event_storm/yaml_parser"
    autoload :BluebookBuilder, "hecks/event_storm/domain_builder"
    autoload :DslGenerator,  "hecks/event_storm/dsl_generator"
    autoload :Result,        "hecks/event_storm/result"
  end

  # Runtime and port components
  autoload :DryRunResult,      "hecks/dry_run_result"
  autoload :Runtime,           "hecks/runtime"
  autoload :Application,       "hecks/runtime"
  # PortWiring is included directly in Runtime, no autoload needed
  autoload :AttachmentMethods, "hecks/runtime/attachment_methods"
  autoload :EventBus,          "hecks/ports/event_bus/event_bus"
  # FilteredEventBus, CrossDomainQuery, CrossDomainView → hecks_multidomain
  autoload :Queue,             "hecks/ports/queue"
  autoload :GateEnforcer,      "hecks/runtime/gate_enforcer"
  autoload :Persistence,       "hecks/ports/repository"
  autoload :Querying,          "hecks/ports/queries"
  autoload :Commands,          "hecks/ports/commands"
  autoload :AggregateDescriber, "hecks/runtime/aggregate_describer"
  autoload :Introspection,     "hecks/runtime/introspection"
  autoload :Versioning,        "hecks/runtime/versioning"
  autoload :ViewBinding,       "hecks/runtime/view_binding"
  autoload :WorkflowExecutor,  "hecks/runtime/workflow_executor"

  # = Hecks::HTTP
  #
  # Namespace for HTTP-related components. Provides Rack-based servers for
  # exposing domains over REST and JSON-RPC, plus OpenAPI and JSON Schema
  # generators for documentation.
  module HTTP
    autoload :DomainServer,       "hecks/extensions/serve/domain_server"
    autoload :MultiDomainServer,  "hecks/extensions/serve/multi_domain_server"
    autoload :RpcServer,          "hecks/extensions/serve/rpc_server"
    autoload :RouteBuilder,       "hecks/extensions/serve/route_builder"
    autoload :OpenapiGenerator,   "hecks/generators/docs/openapi_generator"
    autoload :RpcDiscovery,       "hecks/generators/docs/rpc_discovery"
    autoload :JsonSchemaGenerator,  "hecks/generators/docs/json_schema_generator"
    autoload :TypescriptGenerator,  "hecks/generators/docs/typescript_generator"
  end
end
