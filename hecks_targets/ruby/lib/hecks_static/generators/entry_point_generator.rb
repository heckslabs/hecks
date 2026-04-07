Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Targets::Ruby,
  base_dir: File.expand_path("entry_point_generator", __dir__)
)

# HecksStatic::EntryPointGenerator
#
# Generates two files for the static domain:
# 1. lib/<gem>.rb — autoloads and constants (regeneratable)
# 2. boot.rb — wiring, boot method, serve (stable, written once)
#
module HecksStatic
  class EntryPointGenerator < Hecks::Generator
    include BootWiring

    def initialize(domain)
      @domain = domain
    end

    def generate_entry_point(mod, gem_name)
      @gem_name = gem_name
      lines = []
      lines << "require \"securerandom\""
      lines << "require_relative \"#{gem_name}/runtime/errors\""
      lines << ""
      lines << "module #{mod}"
      lines.concat(runtime_autoloads(gem_name))
      lines.concat(aggregate_autoloads(gem_name))
      lines.concat(port_autoloads(gem_name))
      lines.concat(adapter_autoloads(gem_name))
      lines << ""
      lines.concat(constants)
      lines << "end"
      lines << ""
      lines << "require_relative \"../boot\""
      lines << "#{mod}.boot unless ENV[\"DOMAIN_SKIP_BOOT\"]"
      lines.join("\n") + "\n"
    end

    def generate_boot(mod, gem_name)
      @gem_name = gem_name
      lines = []
      lines << "module #{mod}"
      lines.concat(boot_method(mod))
      lines << "end"
      lines.join("\n") + "\n"
    end

    private

    def runtime_autoloads(gem_name)
      lines = ["  module Runtime"]
      %w[operators event_bus command_bus query_builder model command query specification].each do |f|
        const = f.split("_").map(&:capitalize).join
        lines << "    autoload :#{const}, \"#{gem_name}/runtime/#{f}\""
      end
      lines << "  end"
      lines << ""
      lines
    end

    def aggregate_autoloads(gem_name)
      @domain.aggregates.map do |agg|
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        "  autoload :#{safe}, \"#{gem_name}/#{snake}/#{snake}\""
      end
    end

    def port_autoloads(gem_name)
      lines = ["", "  module Ports"]
      @domain.aggregates.each do |agg|
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        lines << "    autoload :#{safe}Repository, \"#{gem_name}/ports/#{snake}_repository\""
      end
      lines << "  end"
      lines
    end

    def adapter_autoloads(gem_name)
      lines = ["", "  module Adapters"]
      @domain.aggregates.each do |agg|
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        lines << "    autoload :#{safe}MemoryRepository, \"#{gem_name}/adapters/#{snake}_memory_repository\""
      end
      lines << "  end"
      lines
    end

    def constants
      all_roles = @domain.aggregates.flat_map { |a| a.ports.keys }.uniq.map(&:to_s)
      all_roles = ["admin"] if all_roles.empty?

      port_map = {}
      @domain.aggregates.each do |agg|
        safe = domain_constant_name(agg.name)
        agg.ports.each do |role_name, port_def|
          port_map[role_name.to_s] ||= {}
          port_map[role_name.to_s][safe] = port_def.allowed_methods.map(&:to_s)
        end
      end

      [
        "  ROLES = #{all_roles.inspect}.freeze",
        "  PORTS = #{port_map.inspect}.freeze",
        "  VALIDATIONS = #{build_validation_rules.inspect}.freeze"
      ]
    end

    def boot_method(mod)
      all_roles = @domain.aggregates.flat_map { |a| a.ports.keys }.uniq.map(&:to_s)
      all_roles = ["admin"] if all_roles.empty?

      lines = []
      lines << "  class << self"
      lines << "    attr_accessor :event_bus, :command_bus, :current_role"
      lines << "    attr_reader :config"
      lines << ""
      lines << "    def role_allows?(aggregate, action)"
      lines << "      return true unless current_role"
      lines << "      allowed = PORTS.dig(current_role.to_s, aggregate.to_s)"
      lines << "      return true unless allowed"
      lines << "      allowed.include?(action.to_s)"
      lines << "    end"
      lines << ""
      lines << "    def boot(adapter: :memory)"
      lines << "      @current_role ||= \"#{all_roles.first}\""
      lines << "      @config = { adapter: adapter, booted_at: Time.now }"
      lines << "      @event_bus = Runtime::EventBus.new"
      lines << "      @command_bus = Runtime::CommandBus.new(event_bus: @event_bus)"
      lines << "      require_relative \"lib/#{@gem_name}/validations\""
      lines << "      Validations.rules = VALIDATIONS"
      lines << ""
      @domain.aggregates.each do |agg|
        safe = domain_constant_name(agg.name)
        lines << "      #{safe}.repository = case adapter"
        lines << "        when :filesystem"
        lines << "          require_relative \"lib/#{@gem_name}/adapters/filesystem_repository\""
        lines << "          Adapters::FilesystemRepository.new(\"#{safe}\", #{safe})"
        lines << "        else Adapters::#{safe}MemoryRepository.new"
        lines << "        end"
        lines << "      #{safe}.event_bus = @event_bus"
        lines << "      #{safe}.command_bus = @command_bus"
      end
      lines << ""
      @domain.aggregates.each { |agg| wire_commands(lines, agg) }
      @domain.aggregates.each { |agg| wire_queries(lines, agg) }
      @domain.aggregates.each { |agg| wire_persistence(lines, agg) }
      wire_policies(lines)
      lines << ""
      @domain.aggregates.each do |agg|
        safe = domain_constant_name(agg.name)
        lines << "      Object.const_set(:#{safe}, #{safe}) unless Object.const_defined?(:#{safe})"
      end
      lines << "      self"
      lines << "    end"
      lines << ""
      lines << "    def reboot(adapter: :memory)"
      lines << "      boot(adapter: adapter)"
      lines << "    end"
      lines << ""
      lines << "    def on(event_name, &block)"
      lines << "      @event_bus.subscribe(event_name, &block)"
      lines << "    end"
      lines << ""
      lines << "    def events"
      lines << "      @event_bus.events"
      lines << "    end"
      lines << ""
      lines << "    def serve(port: 9292)"
      lines << "      require_relative \"lib/#{@gem_name}/server/domain_app\""
      lines << "      Server::DomainApp.new(self).start(port: port)"
      lines << "    end"
      lines << ""
      lines << "    def domain_info"
      lines << "      {"
      agg_infos = @domain.aggregates.map do |agg|
        safe = domain_constant_name(agg.name)
        cmds = agg.commands.map(&:name).inspect
        ports_hash = agg.ports.values.map { |p| "#{p.name.inspect} => #{p.allowed_methods.map(&:to_s).inspect}" }.join(", ")
        "        #{safe.inspect} => { commands: #{cmds}, ports: { #{ports_hash} }, count: #{safe}.count }"
      end
      lines << agg_infos.join(",\n")
      lines << "      }"
      lines << "    end"
      policy_names = (@domain.aggregates.flat_map { |a| a.policies.map { |p| "#{p.event_name} -> #{p.name}" } } +
                      @domain.policies.map { |p| "#{p.event_name} -> #{p.trigger_command}" }).inspect
      lines << ""
      lines << "    def policy_info"
      lines << "      #{policy_names}"
      lines << "    end"
      lines << "  end"
      lines
    end
  end
end
