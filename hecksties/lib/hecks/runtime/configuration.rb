require "fileutils"
require "hecks_persist/database_connection"
require_relative "configuration/domain_loader"
require_relative "configuration/domain_config_builder"
require_relative "configuration/boot_phase"
require "hecks_persist/sql_setup"
  # Hecks::Configuration
  #
  # Wires Hecks into an application. Supports single or multiple domains with
  # pluggable adapters (memory or SQL). Extensions can be auto-wired or
  # explicitly declared. Use the +gems+ DSL to control which extension gems
  # are required at boot.
  #
  #   Hecks.configure do
  #     gems only: [:audit, :logging]   # require only these
  #     domain "pizzas_domain"
  #     adapter :sqlite
  #     extension :http, port: 9292
  #   end
  #

module Hecks
  # Hecks::Configuration
  #
  # Wires Hecks into an application supporting single or multiple domains with pluggable adapters and extensions.
  #
  class Configuration
    include HecksTemplating::NamingHelpers
    include DatabaseConnection
    include DomainLoader
    include SqlSetup
    include BootPhase

    attr_reader :apps

    def initialize
      @domains = []
      @adapter_type = :memory
      @adapter_options = {}
      @apps = {}
      @ad_hoc_queries = false
      @extensions = {}
      @extensions_explicit = false
      @gem_overrides = nil
      @extensions_loaded = false
    end

    # Control which extension gems are required at boot.
    #
    # @param only [Array<Symbol>, nil] if provided, require only these gems
    # @param except [Array<Symbol>] gems to skip from the AUTO list
    #
    #   gems only: [:audit, :logging]   # require only these
    #   gems except: [:pii]             # skip pii from the AUTO list
    def gems(only: nil, except: [])
      @gem_overrides = { only: only&.map(&:to_sym), except: except.map(&:to_sym) }
    end

    # Register a domain gem to load at boot time.
    #
    # @param gem_name [String] the domain gem name
    # @param version [String, nil] optional version constraint
    # @param path [String, nil] optional local path
    # @yield optional block for listens_to/sends_to declarations
    def domain(gem_name, version: nil, path: nil, &block)
      entry = { gem_name: gem_name, version: version, path: path }
      if block
        builder = DomainConfigBuilder.new
        builder.instance_eval(&block)
        entry[:listens_to] = builder.listens
        entry[:sends_to] = builder.sends
      end
      @domains << entry
    end

    # Register a chapter (domain) to load at boot time.
    # Alias for +domain+ using Bluebook terminology.
    #
    # @param gem_name [String] the domain gem name
    # @param version [String, nil] optional version constraint
    # @param path [String, nil] optional local path
    # @yield optional block for listens_to/sends_to declarations
    def chapter(gem_name, version: nil, path: nil, &block)
      domain(gem_name, version: version, path: path, &block)
    end

    # Set the persistence adapter for all domains.
    #
    # @param type [Symbol] :memory, :sqlite, :postgres, :mysql, :mysql2
    # @param options [Hash] adapter-specific options
    def adapter(type, **options)
      @adapter_type = type
      @adapter_options = options
    end

    def include_ad_hoc_queries
      @ad_hoc_queries = true
    end

    # Auto-wire detected extensions with opt-out/opt-in filtering.
    #
    # @param except [Array<Symbol>] extensions to skip
    # @param only [Array<Symbol>, nil] if provided, only enable these
    def auto_wire(except: [], only: nil)
      @extensions_explicit = true
      require_extensions

      Hecks.extension_registry.each_key do |name|
        next if Hecks.adapter?(name)
        next if except.map(&:to_sym).include?(name)
        next if only && !only.map(&:to_sym).include?(name)
        meta = Hecks.extension_meta[name]
        defaults = meta ? meta[:config].transform_values { |v| v[:default] } : {}
        @extensions[name] = defaults unless @extensions.key?(name)
      end
    end

    # Explicitly enable a single extension.
    #
    # @param name [Symbol, String] the extension name
    # @param options [Hash] extension-specific config
    def extension(name, **options)
      @extensions_explicit = true
      @extensions[name.to_sym] = options
    end

    def extensions_explicit? = @extensions_explicit
    def extensions = @extensions

    # Register an async handler for deferred event processing.
    def async(&block)
      @async_handler = block
    end

    # Boot all registered domains, wire adapters and extensions.
    def boot!
      require_extensions
      @shared_event_bus = EventBus.new
      @db = connect_database if @adapter_type == :sql
      @declarations = build_declarations
      @domains.each { |d| boot_domain(d) }
      bind_app_constant
      activate_rails if defined?(::Rails)
    end

    def domain_obj = @apps.values.first&.domain
    def app = @apps.values.first

    private

    # Require extension gems according to @gem_overrides, idempotently.
    def require_extensions
      return if @extensions_loaded

      @extensions_loaded = true
      require_relative "load_extensions"

      if @gem_overrides.nil?
        LoadExtensions.require_auto
      elsif @gem_overrides[:only]
        @gem_overrides[:only].each { |name| LoadExtensions.require_one(name) }
      else
        (LoadExtensions::AUTO - @gem_overrides[:except]).each { |name| LoadExtensions.require_one(name) }
      end
    end

    def build_declarations
      @domains.each_with_object({}) do |d, decl|
        next unless d[:listens_to]&.any?
        decl[d[:gem_name]] = d[:listens_to].map(&:to_s)
      end
    end

    def event_bus_for(gem_name)
      if @declarations.any?
        FilteredEventBus.new(
          inner: @shared_event_bus,
          domain_gem_name: gem_name,
          allowed_sources: @declarations[gem_name]
        )
      else
        @shared_event_bus
      end
    end

    def bind_app_constant
      first_app = @apps.values.first
      old = $VERBOSE; $VERBOSE = nil
      Object.const_set(:APP, first_app) if first_app
      $VERBOSE = old
    end

    def activate_rails
      require "active_hecks"
      @apps.each_value do |app|
        mod = Object.const_get(domain_module_name(app.domain.name))
        ActiveHecks.activate(mod)
      end
    rescue LoadError
      # active_hecks gem not installed
    end
  end
end
