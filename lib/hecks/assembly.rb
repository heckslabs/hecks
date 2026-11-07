module Hecks
  # Where a boot is put together: the one place that reads the process environment for a boot and
  # plugs the Ruby driving adapter into the dispatcher the runtime hands back.
  #
  # The runtime (`Runtime::Loader`) only loads, checks and dispatches; it reads no environment
  # variable and installs no adapter. Everything a boot takes from outside the domain arrives here.
  #
  # @example
  #   Hecks::Assembly.boot("examples/pizzas/bluebook")
  #     .dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita")
  module Assembly
    # Default for a boot's `environment:` and `engine:` keywords: read `HECKS_ENVIRONMENT` and
    # `HECKS_ENGINE`. An explicit `environment: nil` means no overlay, whatever the variable holds.
    FROM_ENV = :from_env

    # The variable that moves the Hecks world's event tap for a process no hecks command runs: a
    # spec run sets it for itself and every child it starts.
    EVENT_TAP_VARIABLE = "HECKS_EVENT_TAP".freeze

    # The variable that chooses a boot's engine when the caller left `engine:` at its default.
    ENGINE_VARIABLE = "HECKS_ENGINE".freeze

    # The engines a boot can run a domain on: `:ruby` in this process, `:kernel` in the Rust kernel.
    ENGINES = %i[ruby kernel].freeze

    module_function

    # The overlay a boot loads: the caller's own choice (nil meaning none), else the
    # `HECKS_ENVIRONMENT` variable when the caller left the keyword at its default. A domain with
    # no `environments/<name>.*` files ignores either.
    #
    # @param environment [String, nil, Symbol] the overlay a caller passed, or `FROM_ENV`
    # @return [String, nil] the overlay name; nil for none
    def selected_environment(environment)
      return environment unless environment == FROM_ENV

      named = ENV["HECKS_ENVIRONMENT"].to_s.strip
      named.empty? ? nil : named
    end

    # The event tap override a boot hands the runtime: `HECKS_EVENT_TAP` when it is set (a path
    # moves the Hecks world's tap, an empty value switches it off), else nil, which leaves the
    # world's tap where it is. A world that declares no tap ignores it.
    #
    # @return [String, nil] the override
    def event_tap_override = ENV.fetch(EVENT_TAP_VARIABLE, nil)

    # The engine a boot runs on: the caller's own choice, else `HECKS_ENGINE` when the caller left
    # the keyword at its default, else `:ruby`. An unknown engine is refused by name, never
    # replaced by another.
    #
    # @param engine [Symbol, String] `:ruby`, `:kernel`, or `FROM_ENV`
    # @return [Symbol] `:ruby` or `:kernel`
    # @raise [ArgumentError] naming an engine that is neither
    def selected_engine(engine)
      chosen = (engine == FROM_ENV ? engine_from_env : engine).to_s.to_sym
      return chosen if ENGINES.include?(chosen)

      raise ArgumentError, "unknown engine #{chosen.inspect} — one of :ruby, :kernel"
    end

    # @return [String, Symbol] `HECKS_ENGINE`, stripped, or `:ruby` when it is unset or empty
    def engine_from_env
      named = ENV[ENGINE_VARIABLE].to_s.strip
      named.empty? ? :ruby : named
    end

    # Boots a domain directory. See `Runtime::Loader.boot`.
    #
    # @param path [String] path to a domain directory, or a file inside one
    # @param shared [String, nil] a shared-root override
    # @param install_driving [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil, Symbol] the overlay, or `FROM_ENV` for `HECKS_ENVIRONMENT`
    # @param engine [Symbol] `:ruby`, `:kernel`, or `FROM_ENV` for `HECKS_ENGINE`; see
    #   `selected_engine`
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher, Runtime::KernelDispatcher]
    #   the booted dispatcher
    # @raise [ArgumentError] when the engine is neither
    def boot(path, shared: nil, install_driving: true, environment: FROM_ENV, engine: FROM_ENV)
      return boot_kernel(path) if selected_engine(engine) == :kernel

      drive(Runtime::Loader.boot(path, shared: shared, environment: selected_environment(environment),
                                       event_tap: event_tap_override),
            install_driving)
    end

    # Boots a domain on the Rust kernel; see `RustBuild::KernelEngine`. It never falls back.
    #
    # @param path [String] path to a domain directory
    # @return [Runtime::KernelDispatcher]
    def boot_kernel(path)
      require_relative "rust_build/kernel_engine"
      RustBuild::KernelEngine.boot(path)
    end

    # Loads a domain's declarations without binding any adapter. See `Runtime::Loader.describe`.
    #
    # @param path [String] path to a domain directory, or a file inside one
    # @param shared [String, nil] a shared-root override
    # @param environment [String, nil, Symbol] the overlay, or `FROM_ENV` for `HECKS_ENVIRONMENT`
    # @return [Runtime::Loader::Described] the loaded registry, answering `registry`
    def describe(path, shared: nil, environment: FROM_ENV)
      Runtime::Loader.describe(path, shared: shared, environment: selected_environment(environment))
    end

    # Finishes a boot from declarations `describe` already loaded. See
    # `Runtime::Loader.boot_described`.
    #
    # @param described [Runtime::Loader::Described] what `describe` answered
    # @param install_driving [Boolean] install the `Widget::Item.Add`-style facade
    # @param read_only [Boolean] boot without the writes a boot makes; see `Runtime::Loader`
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
    def boot_described(described, install_driving: true, read_only: false)
      drive(Runtime::Loader.boot_described(described, event_tap: event_tap_override, read_only: read_only),
            install_driving)
    end

    # Boots exactly the named files. See `Runtime::Loader.boot_files`.
    #
    # @param paths [String, Array<String>] one or more file paths within the domain
    # @param shared [String, nil] a shared-root override
    # @param install_driving [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil, Symbol] the overlay, or `FROM_ENV` for `HECKS_ENVIRONMENT`
    # @param adapters [Array<String>, nil] exactly the `.adapter` files to load; see the loader
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
    def boot_files(paths, shared: nil, install_driving: true, environment: FROM_ENV, adapters: nil)
      drive(Runtime::Loader.boot_files(paths, shared: shared, environment: selected_environment(environment),
                                              adapters: adapters, event_tap: event_tap_override),
            install_driving)
    end

    # Installs the Ruby driving adapter (`Widget::Item.Add(...)`) closed over `dispatcher`.
    #
    # @param dispatcher [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] a booted
    #   dispatcher
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the same dispatcher
    def bind_runtime(dispatcher)
      Adapters::Driving::Ruby.install(dispatcher)
      dispatcher
    end

    # Installs the Ruby driving adapter only for a domain that declares ports. An adapter behind a
    # port reaches its domain through those constants, so a run that boots without them (a verb
    # run, an outbox redrive) would have the adapter refused with `uninitialized constant`; a
    # domain with no port keeps the cheaper boot.
    #
    # @param dispatcher [Runtime::Dispatcher] a booted dispatcher
    # @return [Runtime::Dispatcher] the same dispatcher
    def bind_ported_runtime(dispatcher)
      registry = dispatcher.registry
      registry.ports.any? ? bind_runtime(dispatcher) : dispatcher
    end

    # The dispatcher, with the Ruby driving adapter installed over it when asked.
    def drive(dispatcher, install_driving) = install_driving ? bind_runtime(dispatcher) : dispatcher
    private_class_method :drive
  end
end
