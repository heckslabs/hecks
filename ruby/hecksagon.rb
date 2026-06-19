# Hecksagon
#
# Hexagonal architecture wiring DSL for Hecks. Declares infrastructure
# concerns separately from domain modeling: gates (access control),
# adapters (persistence), extensions, cross-domain subscriptions,
# and tenancy.
#
# The Hecksagon file sits alongside the Bluebook (domain definition)
# and is loaded during boot to wire the domain into its runtime
# infrastructure.
#
#   Hecks.hecksagon do
#     adapter :sqlite, database: "pizzas.db"
#     gate "Pizza", :admin do
#       allow :find, :all, :create_pizza
#     end
#   end
#
module Hecksagon
  module DSL
    autoload :HecksagonBuilder,   "hecksagon/dsl/hecksagon_builder"
    autoload :GateBuilder,        "hecksagon/dsl/gate_builder"
    autoload :WorldBuilder,       "hecksagon/dsl/world_builder"
    autoload :AnnotationSelector,  "hecksagon/dsl/annotation_selector"
    autoload :FqnBindingProxy,       "hecksagon/dsl/fqn_binding_proxy"
    autoload :BindingBlockCollector, "hecksagon/dsl/fqn_binding_proxy"
    autoload :ContextMapBuilder,    "hecksagon/dsl/context_map_builder"
    autoload :PortContractBuilder,  "hecksagon/dsl/port_contract_builder"
    autoload :ShellAdapterBuilder,  "hecksagon/dsl/shell_adapter_builder"
    autoload :IoAdapterBuilder,     "hecksagon/dsl/io_adapter_builder"
    autoload :LlmAdapterBuilder,    "hecksagon/dsl/llm_adapter_builder"
    autoload :ComputeAdapterBuilder, "hecksagon/dsl/compute_adapter_builder"
    autoload :FrameworkDeclarationBuilder, "hecksagon/dsl/framework_declaration_builder"
    # Sprint 14 — quoted-name `adapter "X" do ... driven on ... end` form.
    autoload :DrivenAdapterBuilder,   "hecksagon/dsl/driven_adapter_builder"
    autoload :DrivenHandlerBuilder,   "hecksagon/dsl/driven_adapter_builder"
    autoload :DrivingHandlerBuilder,  "hecksagon/dsl/driven_adapter_builder"
    autoload :CannedResponseBuilder,  "hecksagon/dsl/driven_adapter_builder"
    autoload :DrivenAdapterValueRepr, "hecksagon/dsl/driven_adapter_builder"
  end

  module Structure
    autoload :Hecksagon,      "hecksagon/structure/hecksagon"
    autoload :GateDefinition, "hecksagon/structure/gate_definition"
    autoload :World,          "hecksagon/structure/world"
    autoload :ShellAdapter,   "hecksagon/structure/shell_adapter"
    autoload :IoAdapter,      "hecksagon/structure/io_adapter"
    autoload :LlmAdapter,     "hecksagon/structure/llm_adapter"
    autoload :ComputeAdapter, "hecksagon/structure/compute_adapter"
    # Sprint 14 — typed IR for the `adapter "X" do ... driven on ... end`
    # form. Mirrors rust/src/hecksagon_ir.rs DrivenAdapter / DrivingAdapter.
    autoload :DrivenAdapter,   "hecksagon/structure/driven_adapter"
    autoload :DrivenHandler,   "hecksagon/structure/driven_adapter"
    autoload :DrivenDispatch,  "hecksagon/structure/driven_adapter"
    autoload :CannedResponse,  "hecksagon/structure/driven_adapter"
    autoload :DrivingAdapter,  "hecksagon/structure/driven_adapter"
    autoload :DrivingHandler,  "hecksagon/structure/driven_adapter"
  end

  # Guarded loader for .hecksagon / .world files (retires Kernel.load
  # for DSL files — see lib/hecks/runtime/boot.rb).
  autoload :Loader,           "hecksagon/loader"

  # Legacy heksagons functionality (merged from heksagons/ gem)
  autoload :StrategicDSL,     "hecksagon/strategic_dsl"
  autoload :DomainMixin,      "hecksagon/domain_mixin"
  autoload :ExtensionsDSL,    "hecksagon/extensions_dsl"
  autoload :AclDefinition,       "hecksagon/acl_definition"
  autoload :DrivenPortRegistry,  "hecksagon/driven_port_registry"
  autoload :ContractValidator, "hecksagon/contract_validator"
end
