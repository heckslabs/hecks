
module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::AutoloadGenerator
    #
    # Generates autoload entry point and per-aggregate autoload declarations for
    # domain gems. The entry point declares autoloads for aggregates, ports, and
    # adapters. Per-aggregate autoloads cover value objects only (commands, events,
    # queries, and policies are auto-discovered via const_missing at runtime).
    # Part of the Generators::Infrastructure layer, consumed by DomainGemGenerator.
    #
    #   gen = AutoloadGenerator.new(domain)
    #   gen.generate_entry_point  # => "module PizzasDomain\n  autoload :Pizza, ..."
    #
    class AutoloadGenerator < Hecks::Generator
      # Creates a new AutoloadGenerator for a domain.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the parsed domain IR
      #   containing aggregates, workflows, views, and services
      def initialize(domain)
        @domain = domain
      end

      # Generates the main entry point Ruby source for the domain gem.
      #
      # The generated file:
      # - Requires +securerandom+
      # - Declares the top-level domain module with +ValidationError+ and +InvariantError+
      # - Emits +autoload+ statements for every aggregate, port, adapter, workflow,
      #   view, and service
      # - Appends an auto-boot block that loads the +Bluebook+ DSL file
      #   and wires a +Hecks::Runtime+ when the gem is installed alongside Hecks
      # - Defines +.boot+ and +.runtime+ singleton methods on the domain module
      #
      # @return [String] the complete Ruby source code for +lib/<gem_name>.rb+
      def generate_entry_point
        gem_name = @domain.gem_name
        mod = domain_module_name(@domain.name)

        lines = []
        lines << "require \"securerandom\""
        lines << ""
        lines << "module #{mod}"
        lines << "  class ValidationError < StandardError"
        lines << "    attr_reader :field, :rule"
        lines << "    def initialize(message = nil, field: nil, rule: nil)"
        lines << "      @field = field; @rule = rule; super(message)"
        lines << "    end"
        lines << "  end"
        lines << "  class InvariantError < StandardError; end"
        lines << ""

        @domain.aggregates.each do |agg|
          safe_name = domain_constant_name(agg.name)
          snake = domain_snake_name(safe_name)
          lines << "  autoload :#{safe_name}, \"#{gem_name}/#{snake}/#{snake}\""
        end

        lines << ""
        lines << "  module Ports"
        @domain.aggregates.each do |agg|
          safe_name = domain_constant_name(agg.name)
          snake = domain_snake_name(safe_name)
          lines << "    autoload :#{safe_name}Repository, \"#{gem_name}/ports/#{snake}_repository\""
        end
        lines << "  end"

        lines << ""
        lines << "  module Adapters"
        @domain.aggregates.each do |agg|
          safe_name = domain_constant_name(agg.name)
          snake = domain_snake_name(safe_name)
          lines << "    autoload :#{safe_name}MemoryRepository, \"#{gem_name}/adapters/#{snake}_memory_repository\""
        end
        lines << "  end"

        unless @domain.workflows.empty?
          lines << ""
          lines << "  module Workflows"
          @domain.workflows.each do |wf|
            snake = domain_snake_name(wf.name)
            lines << "    autoload :#{wf.name}, \"#{gem_name}/workflows/#{snake}\""
          end
          lines << "  end"
        end

        unless @domain.views.empty?
          lines << ""
          lines << "  module Views"
          @domain.views.each do |v|
            snake = domain_snake_name(v.name)
            lines << "    autoload :#{v.name}, \"#{gem_name}/views/#{snake}\""
          end
          lines << "  end"
        end

        unless @domain.services.empty?
          lines << ""
          lines << "  module Services"
          @domain.services.each do |svc|
            snake = domain_snake_name(svc.name)
            lines << "    autoload :#{svc.name}, \"#{gem_name}/services/#{snake}\""
          end
          lines << "  end"
        end

        lines << "end"
        lines << ""
        lines << "# Auto-boot: wire a Runtime when hecks is available and gem is installed."
        lines << "# Add extension gems to your Gemfile to auto-wire:"
        lines << "#   hecks_sqlite  → SQLite persistence"
        lines << "#   hecks_postgres → PostgreSQL persistence"
        lines << "#   hecks_mysql   → MySQL persistence"
        lines << "#   hecks_serve   → HTTP/JSON-RPC server"
        lines << "#   hecks_ai      → MCP server for AI agents"
        lines << "# Remove a gem to unwire that extension. No code changes needed."
        lines << "if defined?(Hecks) && Gem.loaded_specs[\"#{gem_name}\"]"
        lines << "  _hecks_dir = File.join(Gem.loaded_specs[\"#{gem_name}\"].full_gem_path, \"hecks\")"
        lines << "  _hecks_domain_files = Dir[File.join(_hecks_dir, \"*.bluebook\")] if File.directory?(_hecks_dir)"
        lines << "  if _hecks_domain_files&.any?"
        lines << "    _hecks_domain_files.each { |f| Kernel.load(f) }"
        lines << "    #{mod}.instance_variable_set(:@_hecks_domain, Hecks.last_domain)"
        lines << "  end"
        lines << ""
        lines << "  #{mod}.define_singleton_method(:boot) do |**opts, &block|"
        lines << "    domain = instance_variable_get(:@_hecks_domain)"
        lines << "    return unless domain"
        lines << "    @runtime = Hecks.load(domain, **opts, &block)"
        lines << "    Hecks.extension_registry.each { |_name, hook| hook.call(self, domain, @runtime) }"
        lines << "    @runtime"
        lines << "  end"
        lines << ""
        lines << "  #{mod}.define_singleton_method(:runtime) { @runtime }"
        lines << ""
        lines << "  #{mod}.boot unless ENV[\"HECKS_SKIP_BOOT\"]"
        lines << "end"
        lines.join("\n") + "\n"
      end

      # Generates +autoload+ declarations for value objects and entities within a
      # single aggregate class body. Commands, Events, Queries, and Policies are
      # intentionally omitted because they are auto-discovered at runtime via
      # +const_missing+ in +Hecks::Model+.
      #
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
      #   whose child types need autoload declarations
      # @param gem_name [String] the snake_case gem name, used to build require paths
      #   (e.g. +"pizzas_domain"+)
      # @param domain_module [String] the PascalCase domain module name (unused in
      #   current implementation but kept for interface consistency)
      # @return [String] indented autoload lines joined by newlines, suitable for
      #   injection into the aggregate class body; empty string if no value objects
      #   or entities exist
      def generate_aggregate_autoloads(aggregate, gem_name, domain_module)
        safe_name = domain_constant_name(aggregate.name)
        snake = domain_snake_name(safe_name)
        base = "#{gem_name}/#{snake}"
        base_indent = "    "

        lines = []
        aggregate.value_objects.each do |vo|
          vo_snake = domain_snake_name(vo.name)
          lines << "#{base_indent}autoload :#{vo.name}, \"#{base}/#{vo_snake}\""
        end

        aggregate.entities.each do |ent|
          ent_snake = domain_snake_name(ent.name)
          lines << "#{base_indent}autoload :#{ent.name}, \"#{base}/#{ent_snake}\""
        end

        if aggregate.lifecycle
          lines << "#{base_indent}autoload :Lifecycle, \"#{base}/lifecycle\""
        end

        lines.join("\n")
      end

      # Returns autoload lines for value objects and entities as an array of
      # strings (without indentation), for use by the standalone gem generator.
      #
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate]
      # @param gem_name [String]
      # @return [Array<String>]
      def aggregate_autoloads(aggregate, gem_name)
        safe_name = domain_constant_name(aggregate.name)
        snake = domain_snake_name(safe_name)
        base = "#{gem_name}/#{snake}"

        lines = []
        aggregate.value_objects.each do |vo|
          vo_snake = domain_snake_name(vo.name)
          lines << "autoload :#{vo.name}, \"#{base}/#{vo_snake}\""
        end
        aggregate.entities.each do |ent|
          ent_snake = domain_snake_name(ent.name)
          lines << "autoload :#{ent.name}, \"#{base}/#{ent_snake}\""
        end
        lines
      end

    end
    end
  end
end
