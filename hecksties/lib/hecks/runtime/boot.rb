
# Hecks::Boot
#
# Loads a domain from a directory, validates, builds, and wires a Runtime.
# Single domain: expects Bluebook. Multi-domain: expects hecks_domains/.
#
#   app = Hecks.boot(__dir__)
#   app = Hecks.boot(__dir__, adapter: :sqlite)
#
module Hecks
  module Boot
    include HecksTemplating::NamingHelpers

    # @return [Hecks::EventBus, nil] the shared bus from the last multi-domain boot
    attr_reader :shared_event_bus

    # @param dir [String] directory containing Bluebook or hecks_domains/
    # @param adapter [Symbol, Hash] persistence adapter (:memory, :sqlite, etc.)
    # @yield optional block on domain module for declaring connections
    # @return [Hecks::Runtime, Array<Hecks::Runtime>]
    def boot(dir = Dir.pwd, adapter: :memory, &block)
      require_relative "load_extensions"
      LoadExtensions.require_auto

      multi_dir = find_domains_dir(dir)
      if multi_dir
        require "hecks_multidomain"
        return boot_multi(dir, multi_dir, adapter: adapter, &block)
      end

      # Check for single-file Bluebook composition (Hecks.bluebook)
      bluebook_ir = detect_bluebook_file(dir)
      if bluebook_ir
        runtimes = boot_domains(bluebook_ir.chapters)
        autoload_services(dir)
        return runtimes
      end

      domain, mod = load_single_domain(dir)
      mod.instance_eval(&block) if block
      runtime = Runtime.new(domain)
      wire_persistence(mod, domain, runtime, adapter)
      fire_extensions(mod, domain, runtime)
      autoload_services(dir)
      runtime
    end

    private

    def persistence_extension?(name)
      Hecks.adapter?(name)
    end

    # Detect a single Bluebook file that uses Hecks.bluebook (not Hecks.domain).
    # Returns the BluebookStructure IR if found, nil otherwise.
    def detect_bluebook_file(dir)
      bluebooks = Dir[File.join(dir, "*Bluebook")].sort
      bluebooks = Dir[File.join(dir, "bluebook", "*Bluebook")].sort if bluebooks.empty?
      return nil if bluebooks.empty?

      # Check if the file content uses Hecks.bluebook
      bluebooks.each do |f|
        content = File.read(f)
        next unless content.include?("Hecks.bluebook")
        Hecks.last_bluebook = nil
        Kernel.load(f)
        return Hecks.last_bluebook if Hecks.last_bluebook
      end
      nil
    end

    def find_domains_dir(dir)
      candidates = [File.join(dir, "hecks_domains"), File.join(dir, "domains")]
      found = candidates.find { |d| File.directory?(d) }
      return found if found

      # bluebook/ subfolder with multiple Bluebook files = multi-domain
      bluebook_dir = File.join(dir, "bluebook")
      return bluebook_dir if File.directory?(bluebook_dir) && Dir[File.join(bluebook_dir, "*Bluebook")].size > 1

      nil
    end

    def load_single_domain(dir)
      # Look for *Bluebook files at root, then in bluebook/ subfolder
      bluebooks = Dir[File.join(dir, "*Bluebook")].sort
      bluebooks = Dir[File.join(dir, "bluebook", "*Bluebook")].sort if bluebooks.empty?
      raise Hecks::DomainLoadError, "No *Bluebook files found in #{dir} or #{dir}/bluebook/" if bluebooks.empty?

      bluebooks.each { |f| Kernel.load(f) }
      domain = Hecks.last_domain
      domain.source_path = bluebooks.first

      # Auto-discover and load Hecksagon file (infrastructure capabilities)
      hecksagons = Dir[File.join(dir, "*Hecksagon")].sort
      hecksagons = Dir[File.join(dir, "bluebook", "*Hecksagon")].sort if hecksagons.empty?
      hecksagons.each { |f| Kernel.load(f) }

      mod = load_domain(domain)
      load_stubs(dir, domain)
      mod.extend(Hecks::DomainConnections) unless mod.respond_to?(:connections)
      [domain, mod]
    end

    def wire_persistence(mod, domain, runtime, adapter)
      persist = mod.connections[:persist] || {}
      boot_cfg = adapter == :memory ? nil : normalize_adapter(adapter)
      effective = persist[:default] || persist.values.first || boot_cfg
      return unless effective

      hook = Hecks.extension_registry[effective[:type]]
      if hook
        hook.call(mod, domain, runtime)
      elsif effective[:type] == :mongodb
        require "hecks_mongodb"
        boot_with_mongo(domain, effective, runtime)
      elsif sql_adapter_type?(effective[:type])
        require "hecks_persist/sql_boot"
        boot_with_sql(domain, effective, runtime)
      end
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
      Dir[File.join(services_dir, "*.rb")].sort.each { |f| require f }
    end

    def boot_multi(dir, domains_dir, adapter: :memory, &block)
      # Support both *.rb (legacy) and *Bluebook files
      domain_files = Dir[File.join(domains_dir, "*Bluebook")].sort
      domain_files = Dir[File.join(domains_dir, "*.rb")].sort if domain_files.empty?
      raise Hecks::DomainLoadError, "No Bluebook or .rb files in #{domains_dir}" if domain_files.empty?

      domains = domain_files.map { |path| eval(File.read(path), nil, path, 1) }
      domains.each { |d| load_stubs(dir, d) }
      runtimes = boot_domains(domains)
      autoload_services(dir)
      runtimes
    end

    # Core multi-domain boot: takes an array of Domain IRs, validates,
    # compiles, wires event buses and cross-domain queues, fires extensions.
    # Used by boot_multi (file-based) and open (Bluebook IR-based).
    #
    # @param domains [Array<DomainModel::Structure::Domain>]
    # @return [Array<Runtime>]
    def boot_domains(domains)
      require "hecks_multidomain"
      Hecks::MultiDomain::Validator.validate_no_cross_domain_references(domains)
      domains.each { |d| load_domain(d) }

      shared_bus = EventBus.new
      @shared_event_bus = shared_bus
      directionality = Hecks::MultiDomain::Directionality.build(domains)
      runtimes = domains.map do |d|
        bus = directionality.any? ? FilteredEventBus.new(inner: shared_bus, domain_gem_name: d.gem_name, allowed_sources: directionality[d.gem_name]) : shared_bus
        Runtime.new(d, event_bus: bus)
      end
      Hecks::MultiDomain::QueueWiring.wire(domains, runtimes)

      domains.each_with_index do |domain, i|
        mod = Object.const_get(domain_module_name(domain.name))
        fire_extensions(mod, domain, runtimes[i])
      end

      runtimes
    end

    def load_stubs(dir, domain)
      stubs_dir = File.join(dir, "lib", domain.gem_name)
      return unless File.directory?(stubs_dir)
      Dir[File.join(stubs_dir, "**/*.rb")].sort.each { |f| Kernel.load(f) }
    end

    def filtered_bus(shared_bus, domain, all_domains)
      @_directionality ||= EventDirectionality.build(all_domains)
      return shared_bus unless @_directionality.any?
      FilteredEventBus.new(
        inner: shared_bus,
        domain_gem_name: domain.gem_name,
        allowed_sources: @_directionality[domain.gem_name]
      )
    end

    def normalize_adapter(adapter)
      adapter.respond_to?(:to_hash) ? adapter : { type: adapter }
    end

    def sql_adapter_type?(type)
      %i[sqlite postgres mysql mysql2].include?(type)
    end

    def boot_with_sql(domain, adapter_config, runtime)
      db = SqlBoot.connect(adapter_config)
      adapters = SqlBoot.setup(domain, db)
      adapters.each { |name, repo| runtime.swap_adapter(name, repo) }
    end

    def boot_with_mongo(domain, adapter_config, runtime)
      client = MongoBoot.connect(adapter_config)
      adapters = MongoBoot.setup(domain, client)
      adapters.each { |name, repo| runtime.swap_adapter(name, repo) }
    end
  end
end
