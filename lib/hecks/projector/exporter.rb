require "json"
require_relative "../ports/persistence"
require_relative "exporter/bindings"
require_relative "exporter/translations"

module Hecks
  module Projector
    # Registry-wide serialization to Hash/JSON, for the canonical bluebook IR,
    # binding facts, and translation edges (declared and compiled).
    #
    # The capability bindings (`authorization`, `membership`, ...) are `Exporter::Bindings` and
    # the translation edges (`translations`, `translation_hash`, ...) are `Exporter::Translations`;
    # both are reachable as methods of `Exporter` itself.
    module Exporter
      module_function

      # Exports every booted bluebook's own canonical IR.
      #
      # @param registry [Runtime::Registry] the booted registry to export
      # @return [Hash{String => Hash}] each domain name, mapped to its bluebook's `to_h`
      def call(registry)
        registry.bluebooks.transform_values(&:to_h)
      end

      # Exports every booted bluebook's own canonical IR as JSON.
      #
      # @param registry [Runtime::Registry] the booted registry to export
      # @return [String] `call`'s output, as pretty-printed JSON
      def json(registry)
        JSON.pretty_generate(call(registry))
      end

      # Whether each aggregate is bound to a lineage-capable adapter — a per-deployment
      # binding fact, not part of the declared IR `call` exports (ADR 0001).
      # Empty when the era persistence plugin isn't loaded, rather than raising.
      #
      # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
      # @param domain_name [String] the domain to check era-adapter lineage capability for
      # @return [Hash{Symbol => Array<Hash{Symbol => String}>}] `:capable_aggregates`,
      #   each a `:name`/`:storage_name` Hash; empty when the era plugin is unloaded or
      #   nothing this domain binds is lineage-capable
      # @raise [KeyError] if `domain_name` is not a loaded domain
      def lineage(registry, domain_name)
        return { capable_aggregates: [] } unless Ports::Persistence.plugin?(:era)

        bluebook = registry.bluebooks.fetch(domain_name)
        capable = bluebook.aggregates.select do |aggregate|
          adapter_name = Runtime::EraCheck.adapter_for(registry, domain_name, aggregate)
          Runtime::EraCheck.lineage_capable?(registry, adapter_name)
        end

        { capable_aggregates: capable.map { |aggregate| { name: aggregate.name, storage_name: aggregate.storage_name } } }
      end

      # Every aggregate's declared persistence adapter (`persisted_by`) — a binding
      # fact like `lineage`, not part of the declared IR `call` exports (ADR 0001).
      #
      # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
      # @param domain_name [String] the domain to export persistence bindings for
      # @return [Hash{Symbol => Array<Hash{Symbol => Object}>}] `:aggregates`, each a
      #   `:name`/`:storage_name`/`:adapter` Hash
      # @raise [KeyError] if `domain_name` is not a loaded domain
      # @raise [Runtime::WiringError] if an aggregate has no authoritative bind, more
      #   than one, or a bind with a role this port does not support
      def persistence(registry, domain_name)
        bluebook = registry.bluebooks.fetch(domain_name)
        aggregates = bluebook.aggregates.map do |aggregate|
          adapter = Ports::Persistence::BindingPolicy.resolve(registry, domain_name, aggregate).adapter
          { name: aggregate.name, storage_name: aggregate.storage_name, adapter: adapter }
        end

        { aggregates: aggregates }
      end

      extend Bindings
      extend Translations
    end
  end
end
