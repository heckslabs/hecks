# Register all built-in generators with the registry.
# Loaded after all generator classes are defined.
#
module Hecks
  module Generators
    # Per-aggregate generators (one per aggregate)
    register(:port,           Infrastructure::PortGenerator,          scope: :aggregate)
    register(:memory_adapter, Infrastructure::MemoryAdapterGenerator, scope: :aggregate)
    register(:aggregate,      Domain::AggregateGenerator,             scope: :aggregate)
    register(:lifecycle,      Domain::LifecycleGenerator,             scope: :aggregate)

    # Per-child generators (iterate aggregate collections)
    register(:value_object,  Domain::ValueObjectGenerator,    scope: :child, source: :value_objects)
    register(:entity,        Domain::EntityGenerator,         scope: :child, source: :entities)
    register(:event,         Domain::EventGenerator,          scope: :child, source: :events)
    register(:policy,        Domain::PolicyGenerator,         scope: :child, source: :policies)
    register(:subscriber,    Domain::SubscriberGenerator,     scope: :child, source: :subscribers)
    register(:specification, Domain::SpecificationGenerator,  scope: :child, source: :specifications, mixin: "Hecks::Specification")
    register(:command,       Domain::CommandGenerator,        scope: :child, source: :commands,       mixin: "Hecks::Command")
    register(:query,         Domain::QueryGenerator,          scope: :child, source: :queries,        mixin: "Hecks::Query")

    # Per-domain generators (one per domain)
    register(:workflow, Domain::WorkflowGenerator, scope: :domain, source: :workflows)
    register(:view,     Domain::ViewGenerator,     scope: :domain, source: :views)
    register(:service,  Domain::ServiceGenerator,  scope: :domain, source: :services)
  end
end
