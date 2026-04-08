# Hecks::Boot
#
# Loads all .bluebook domains from a hecks/ directory, validates, builds,
# and wires Runtimes with shared event bus and extensions.
#
#   runtimes = Hecks.boot(__dir__)
#
module Hecks
  # Hecks::Boot
  #
  # Boots all domains from the hecks/ directory in a project.
  #
  module Boot
    include HecksTemplating::NamingHelpers

    # @return [Hecks::EventBus, nil] the shared bus from the last boot
    attr_reader :shared_event_bus

    # @param dir [String] project directory containing hecks/ subdirectory
    # @return [Array<Hecks::Runtime>]
    def boot(dir = Dir.pwd)
      require "hecks/runtime/load_extensions"
      LoadExtensions.require_auto

      hecks_dir = File.join(dir, "hecks")
      raise Hecks::BluebookLoadError, "No hecks/ directory in #{dir}" unless File.directory?(hecks_dir)

      bluebooks = find_domain_files(hecks_dir)
      raise Hecks::BluebookLoadError, "No .bluebook files in #{hecks_dir}" if bluebooks.empty?

      find_hecksagon_files(hecks_dir).each { |f| Kernel.load(f) }
      find_world_files(hecks_dir).each { |f| Kernel.load(f) }

      domains = bluebooks.map { |path| Kernel.load(path); Hecks.last_domain }
      domains.each { |d| load_stubs(dir, d) }
      runtimes = boot_domains(domains)
      autoload_services(dir)
      runtimes.size == 1 ? runtimes.first : runtimes
    end

    private

    def persistence_extension?(name)
      Hecks.adapter?(name)
    end

    def fire_extensions(mod, domain, runtime)
      config = Hecks.configuration
      explicit = config&.extensions_explicit?

      eligible = Hecks.extension_registry.select do |name, hook|
        next false if persistence_extension?(name)
        next false unless hook.respond_to?(:call)
        next false if explicit && !config.extensions.key?(name)
        true
      end

      driven, driving, untyped = partition_by_adapter_type(eligible)
      (driven + untyped + driving).each { |_name, hook| hook.call(mod, domain, runtime) }

      runtime.check_auth_coverage!
      runtime.check_reference_coverage!
    end

    def partition_by_adapter_type(extensions)
      driven  = []
      driving = []
      untyped = []
      extensions.each do |name, hook|
        meta = Hecks.extension_meta[name]
        case meta&.dig(:adapter_type)
        when :driven  then driven  << [name, hook]
        when :driving then driving << [name, hook]
        else               untyped << [name, hook]
        end
      end
      [driven, driving, untyped]
    end

    def autoload_services(dir)
      services_dir = File.join(dir, "services")
      return unless File.directory?(services_dir)
      Dir[File.join(services_dir, "*.rb")].sort.each { |service_file| require service_file }
    end

    # Boot all domains: validates, compiles, wires event buses and
    # cross-domain queues, fires extensions.
    #
    # @param domains [Array<BluebookModel::Structure::Domain>]
    # @return [Array<Runtime>]
    def boot_domains(domains)
      require "hecks_multidomain"
      Hecks::MultiDomain::Validator.validate_no_cross_domain_references(domains)
      domains.each { |d| load_bluebook(d) }

      shared_bus = EventBus.new
      @shared_event_bus = shared_bus
      directionality = Hecks::MultiDomain::Directionality.build(domains)
      runtimes = domains.map do |domain|
        bus = directionality.any? ? FilteredEventBus.new(inner: shared_bus, bluebook_gem_name: domain.gem_name, allowed_sources: directionality[domain.gem_name]) : shared_bus
        Runtime.new(domain, event_bus: bus)
      end
      Hecks::MultiDomain::QueueWiring.wire(domains, runtimes)

      domains.each_with_index do |domain, idx|
        mod = Object.const_get(bluebook_module_name(domain.name))
        fire_extensions(mod, domain, runtimes[idx])
      end

      runtimes
    end

    def load_stubs(dir, domain)
      stubs_dir = File.join(dir, "lib", domain.gem_name)
      return unless File.directory?(stubs_dir)
      Dir[File.join(stubs_dir, "**/*.rb")].sort.each { |stub_file| Kernel.load(stub_file) }
    end

    def filtered_bus(shared_bus, domain, all_domains)
      @_directionality ||= EventDirectionality.build(all_domains)
      return shared_bus unless @_directionality.any?
      FilteredEventBus.new(
        inner: shared_bus,
        bluebook_gem_name: domain.gem_name,
        allowed_sources: @_directionality[domain.gem_name]
      )
    end

    # Find domain definition files: *.bluebook
    def find_domain_files(dir)
      Dir[File.join(dir, "*.bluebook")].sort
    end

    # Find hecksagon files: hecksagon.hec
    def find_hecksagon_files(dir)
      Dir[File.join(dir, "hecksagon.hec")].sort
    end

    # Find world files: world.hec
    def find_world_files(dir)
      Dir[File.join(dir, "world.hec")].sort
    end

  end
end
