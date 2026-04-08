module Hecks
  class Runtime
    # Hecks::Runtime::PortSetup
    #
    # Wires all five ports onto aggregate classes: repository (persistence),
    # commands, queries, introspection, versioning, attachments, and port
    # enforcement. Called once during Runtime initialization and again when
    # an adapter is swapped.
    #
    #   class Runtime
    #     include PortSetup
    #   end
    #
    module PortSetup
      include HecksTemplating::NamingHelpers
      private

      # Wires all ports for every aggregate in the domain.
      #
      # Iterates through each aggregate definition and calls +wire_aggregate+
      # to bind persistence, commands, querying, introspection, versioning,
      # attachments, query objects, and port enforcement.
      #
      # @return [void]
      def wire_ports!
        @domain.aggregates.each { |agg| wire_aggregate(agg) }
      end

      # Re-wires ports for a single aggregate by name.
      #
      # Useful when an adapter is swapped at runtime and only one aggregate
      # needs to be re-wired without re-initializing the entire domain.
      #
      # @param name [String, Symbol] the name of the aggregate to re-wire
      # @return [void]
      def wire_aggregate!(name)
        agg = @domain.aggregates.find { |a| a.name == name.to_s }
        wire_aggregate(agg) if agg
      end

      # Wires all port bindings for a single aggregate.
      #
      # This is the core wiring method that binds:
      # - Persistence (find, all, save, delete, etc.) via the repository
      # - Commands (create, update, and custom commands) via the command bus
      # - Querying (where, first, last, count) for in-memory filtering
      # - Introspection (hecks_attributes, hecks_aggregate) for reflection
      # - Versioning (versions, at_version) if the aggregate is versioned
      # - Attachments (attach, attachments) if the aggregate is attachable
      # - Query objects defined in the DSL
      # - Port enforcement to restrict methods based on the active port
      #
      # @param agg [Hecks::BluebookModel::Aggregate] the aggregate definition from the domain model
      # @return [void]
      def wire_aggregate(agg)
        agg_class = @mod.const_get(bluebook_constant_name(agg.name))
        repo = ownership_scoped_repo(agg, @repositories[agg.name])
        defaults = build_defaults(agg)

        Persistence.bind(agg_class, agg, repo)
        Commands.bind(agg_class, agg, @command_bus, repo, defaults)
        Querying.bind(agg_class, agg)
        Introspection.bind(agg_class, agg)
        Versioning.bind(agg_class, repo) if runtime_option?(agg.name, :versioned)
        AttachmentMethods.bind(agg_class) if runtime_option?(agg.name, :attachable)
        wire_query_objects(agg, agg_class)
        GateEnforcer.new(gate_name: @gate_name, hecksagon: @hecksagon).enforce!(agg, agg_class)
      end

      # Wraps the repository with an OwnershipScopedRepository when the active
      # gate declares +owned_by+ or when tenancy is +:row+.
      #
      # @param agg [Hecks::BluebookModel::Aggregate] the aggregate definition
      # @param repo [Object] the inner repository instance
      # @return [Object] the repo, possibly wrapped with ownership scoping
      def ownership_scoped_repo(agg, repo)
        gate_def = @hecksagon&.gate_for(agg.name, @gate_name) if @gate_name && @hecksagon
        if gate_def&.ownership_field
          require "hecks/extensions/tenancy_support/ownership_scoped_repository"
          HecksTenancy::OwnershipScopedRepository.new(
            repo,
            ownership_field: gate_def.ownership_field,
            identity_source: -> { Hecks.current_user }
          )
        elsif @hecksagon&.tenancy == :row
          require "hecks/extensions/tenancy_support/ownership_scoped_repository"
          HecksTenancy::OwnershipScopedRepository.new(
            repo,
            ownership_field: :tenant_id,
            identity_source: -> { Hecks.tenant }
          )
        else
          repo
        end
      end

      # Builds a default values hash for the aggregate's attributes.
      #
      # List-type attributes default to an empty array; all others default to nil.
      # These defaults are passed to the Commands binding so that new aggregates
      # are initialized with sensible values for omitted attributes.
      #
      # @param agg [Hecks::BluebookModel::Aggregate] the aggregate definition
      # @return [Hash{String => Array, nil}] attribute name to default value mapping
      def build_defaults(agg)
        agg.attributes.each_with_object({}) { |attr, h| h[attr.name] = attr.list? ? [] : nil }
      end

      # Checks whether a runtime infrastructure option is enabled for an aggregate.
      # Options are registered via +Runtime#enable+ in the config block.
      #
      # @param aggregate_name [String] the aggregate name
      # @param option [Symbol] the option key (e.g., :versioned, :attachable)
      # @return [Boolean]
      def runtime_option?(aggregate_name, option)
        (@runtime_options || {}).dig(aggregate_name.to_s, option) || false
      end

      # Wires DSL-defined query objects as class methods on the aggregate class.
      #
      # For each query defined on the aggregate:
      # - If a matching query class exists under +AggClass::Queries+ and responds
      #   to +repository=+, injects the repository and creates a class method
      #   that delegates to +query_class.call+
      # - Otherwise, creates a class method that evaluates the query's block
      #   against a new +QueryBuilder+ instance backed by the repository
      #
      # @param agg [Hecks::BluebookModel::Aggregate] the aggregate definition
      # @param agg_class [Class] the runtime aggregate class to add query methods to
      # @return [void]
      def wire_query_objects(agg, agg_class)
        repo = @repositories[agg.name]
        queries_mod = begin; agg_class.const_get(:Queries); rescue NameError; nil; end

        agg.queries.each do |query|
          method_name = bluebook_snake_name(query.name).to_sym
          query_class = begin
            queries_mod&.const_defined?(query.name, false) && queries_mod.const_get(query.name)
          rescue StandardError
            nil
          end

          if query_class&.respond_to?(:repository=)
            query_class.repository = repo
            agg_class.define_singleton_method(method_name) { |*args| query_class.call(*args) }
          else
            query_block = query.block
            agg_class.define_singleton_method(method_name) do |*args|
              builder = Querying::QueryBuilder.new(repo)
              builder.instance_exec(*args, &query_block)
            end
          end
        end
      end
    end
  end
end
