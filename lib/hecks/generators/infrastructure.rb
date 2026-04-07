module Hecks
  module Generators
    # Hecks::Generators::Infrastructure
    #
    # Parent module for infrastructure generators. Autoloads generators for
    # repository ports, memory adapters, autoload entry points, RSpec specs,
    # and the top-level domain gem generator (DomainGemGenerator). Part of
    # the Generators layer, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Subcomponents
    #
    # - +PortGenerator+ -- generates repository port interfaces (abstract modules with
    #   +NotImplementedError+ stubs for +find+, +save+, +delete+)
    # - +MemoryAdapterGenerator+ -- generates in-memory repository implementations
    #   that store aggregates in a +Hash+, including a +query+ method for filtering
    # - +AutoloadGenerator+ -- generates the +autoload+ entry point file and
    #   per-aggregate autoload declarations for value objects and entities
    # - +SpecGenerator+ -- generates behavioral RSpec specs for aggregates, commands,
    #   events, value objects, and entities
    # - +SpecHelpers+ -- shared private helpers for building example arguments and
    #   values in generated specs
    # - +DomainGemGenerator+ -- orchestrates the full gem generation pipeline,
    #   delegating to all other generators and writing files to disk
    #
    module Infrastructure
      autoload :PortGenerator,          "hecks/generators/infrastructure/port_generator"
      autoload :MemoryAdapterGenerator, "hecks/generators/infrastructure/memory_adapter_generator"
      autoload :AutoloadGenerator,      "hecks/generators/infrastructure/autoload_generator"
      autoload :SpecGenerator,          "hecks/generators/infrastructure/spec_generator"
      autoload :SpecHelpers,            "hecks/generators/infrastructure/spec_helpers"
      autoload :DomainGemGenerator,     "hecks/generators/infrastructure/domain_gem_generator"
      autoload :FrameworkGemGenerator, "hecks/generators/infrastructure/framework_gem_generator"
      autoload :SelfHostDiff,          "hecks/generators/infrastructure/self_host_diff"
    end
  end
end
