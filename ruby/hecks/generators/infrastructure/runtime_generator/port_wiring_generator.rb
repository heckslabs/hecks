module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::PortWiringGenerator
    #
    # Generates a static module that wires all five ports onto aggregate
    # classes: persistence, commands, querying, introspection, versioning,
    # attachments, and gate enforcement. Replaces the hand-written
    # Hecks::Runtime::PortSetup mixin which iterates the domain IR at boot
    # time. The generated module emits one explicit wire method per aggregate.
    #
    # == Usage
    #
    #   gen = PortWiringGenerator.new(domain, domain_module: "PizzasDomain")
    #   gen.generate
    #   # => "module Hecks\n  class Runtime\n    module Generated\n      module PortWiring\n  ..."
    #
    class PortWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR
      #   providing +aggregates+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the PortWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing:
      # - A private +wire_ports!+ dispatcher that calls each aggregate's wire method
      # - A +wire_aggregate!+ method for runtime re-wiring by name
      # - One +wire_<name>+ method per aggregate with explicit bind calls
      # - Helper methods: +ownership_scoped_repo+, +build_defaults+,
      #   +runtime_option?+, +wire_query_objects+
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module PortWiring"
        lines << "        include HecksTemplating::NamingHelpers"
        lines << "        private"
        lines << ""
        lines.concat(wire_ports_lines)
        lines << ""
        lines.concat(wire_aggregate_bang_lines)
        @domain.aggregates.each do |agg|
          lines << ""
          lines.concat(wire_single_lines(agg))
        end
        lines << ""
        lines.concat(helper_lines)
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Emits the +wire_ports!+ dispatcher method.
      #
      # @return [Array<String>] source lines
      def wire_ports_lines
        lines = []
        lines << "        def wire_ports!"
        @domain.aggregates.each do |agg|
          lines << "          wire_#{bluebook_snake_name(agg.name)}"
        end
        lines << "        end"
        lines
      end

      # Emits the +wire_aggregate!+ method for re-wiring a single aggregate by name.
      #
      # @return [Array<String>] source lines
      def wire_aggregate_bang_lines
        lines = []
        lines << "        def wire_aggregate!(name)"
        lines << "          method_name = \"wire_\#{bluebook_snake_name(name)}\""
        lines << "          send(method_name) if respond_to?(method_name, true)"
        lines << "        end"
        lines
      end

      # Emits the +wire_<name>+ method for a single aggregate.
      #
      # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      # @return [Array<String>] source lines
      def wire_single_lines(agg)
        name = bluebook_constant_name(agg.name)
        snake = bluebook_snake_name(agg.name)
        lines = []
        lines << "        def wire_#{snake}"
        lines << "          agg = @domain.aggregates.find { |a| a.name == \"#{agg.name}\" }"
        lines << "          agg_class = @mod.const_get(\"#{name}\")"
        lines << "          repo = ownership_scoped_repo(agg, @repositories[\"#{agg.name}\"])"
        lines << "          defaults = build_defaults(agg)"
        lines << ""
        lines << "          Persistence.bind(agg_class, agg, repo)"
        lines << "          Commands.bind(agg_class, agg, @command_bus, repo, defaults)"
        lines << "          Querying.bind(agg_class, agg)"
        lines << "          Introspection.bind(agg_class, agg)"
        lines << "          Versioning.bind(agg_class, repo) if runtime_option?(agg.name, :versioned)"
        lines << "          AttachmentMethods.bind(agg_class) if runtime_option?(agg.name, :attachable)"
        lines << "          wire_query_objects(agg, agg_class)"
        lines << "          GateEnforcer.new(gate_name: @gate_name, hecksagon: @hecksagon).enforce!(agg, agg_class)"
        lines << "        end"
        lines
      end

      # Emits the helper methods that the wire methods depend on.
      #
      # @return [Array<String>] source lines
      def helper_lines
        lines = []
        lines.concat(ownership_scoped_repo_lines)
        lines << ""
        lines.concat(build_defaults_lines)
        lines << ""
        lines.concat(runtime_option_lines)
        lines << ""
        lines.concat(wire_query_objects_lines)
        lines
      end

      # Emits the +ownership_scoped_repo+ helper.
      #
      # @return [Array<String>] source lines
      def ownership_scoped_repo_lines
        [
          '        def ownership_scoped_repo(agg, repo)',
          '          gate_def = @hecksagon&.gate_for(agg.name, @gate_name) if @gate_name && @hecksagon',
          '          if gate_def&.ownership_field',
          '            require "hecks/extensions/tenancy_support/ownership_scoped_repository"',
          '            HecksTenancy::OwnershipScopedRepository.new(',
          '              repo,',
          '              ownership_field: gate_def.ownership_field,',
          '              identity_source: -> { Hecks.current_user }',
          '            )',
          '          elsif @hecksagon&.tenancy == :row',
          '            require "hecks/extensions/tenancy_support/ownership_scoped_repository"',
          '            HecksTenancy::OwnershipScopedRepository.new(',
          '              repo,',
          '              ownership_field: :tenant_id,',
          '              identity_source: -> { Hecks.tenant }',
          '            )',
          '          else',
          '            repo',
          '          end',
          '        end'
        ]
      end

      # Emits the +build_defaults+ helper.
      #
      # @return [Array<String>] source lines
      def build_defaults_lines
        [
          '        def build_defaults(agg)',
          '          agg.attributes.each_with_object({}) { |attr, h| h[attr.name] = attr.list? ? [] : nil }',
          '        end'
        ]
      end

      # Emits the +runtime_option?+ helper.
      #
      # @return [Array<String>] source lines
      def runtime_option_lines
        [
          '        def runtime_option?(aggregate_name, option)',
          '          (@runtime_options || {}).dig(aggregate_name.to_s, option) || false',
          '        end'
        ]
      end

      # Emits the +wire_query_objects+ helper.
      #
      # @return [Array<String>] source lines
      def wire_query_objects_lines
        [
          '        def wire_query_objects(agg, agg_class)',
          '          repo = @repositories[agg.name]',
          '          queries_mod = begin; agg_class.const_get(:Queries); rescue NameError; nil; end',
          '          agg.queries.each do |query|',
          '            method_name = bluebook_snake_name(query.name).to_sym',
          '            query_class = begin',
          '              queries_mod&.const_defined?(query.name, false) && queries_mod.const_get(query.name)',
          '            rescue StandardError',
          '              nil',
          '            end',
          '            if query_class&.respond_to?(:repository=)',
          '              query_class.repository = repo',
          '              agg_class.define_singleton_method(method_name) { |*args| query_class.call(*args) }',
          '            else',
          '              query_block = query.block',
          '              agg_class.define_singleton_method(method_name) do |*args|',
          '                builder = Querying::QueryBuilder.new(repo)',
          '                builder.instance_exec(*args, &query_block)',
          '              end',
          '            end',
          '          end',
          '        end'
        ]
      end
    end
    end
  end
end
