# Hecks::Generators::Registry
#
# Generator registry. Modules register their generators here.
# InMemoryLoader and file writers iterate the registry instead of
# hardcoding generator classes.
#
#   Hecks::Generators.register(:aggregate, Generators::Domain::AggregateGenerator)
#   Hecks::Generators.register(:value_object, Generators::Domain::ValueObjectGenerator, scope: :child)
#   Hecks::Generators.register(:workflow, Generators::Domain::WorkflowGenerator, scope: :domain)
#
require_relative "../generator"

module Hecks
  module Generators
    @registry = { aggregate: [], child: [], domain: [] }

    # Register a generator.
    #
    # @param name [Symbol] identifier (e.g., :aggregate, :command, :workflow)
    # @param klass [Class] the generator class (must respond to .new(obj, **opts).generate)
    # @param scope [Symbol] :aggregate (per-aggregate), :child (per-aggregate-child), :domain (per-domain)
    # @param source [Symbol] which IR collection to iterate (e.g., :value_objects, :events, :workflows)
    # @param mixin [String, nil] mixin to inject after class definition (e.g., "Hecks::Command")
    def self.register(name, klass, scope: :aggregate, source: nil, mixin: nil)
      @registry[scope] << { name: name, klass: klass, source: source, mixin: mixin }
    end

    # All registered generators for a scope.
    def self.for(scope)
      @registry[scope.to_sym] || []
    end

    # All registered generator names.
    def self.registered
      @registry.values.flatten.map { |g| g[:name] }
    end
  end
end
