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
    # Default for a boot's `environment:` keyword: read `HECKS_ENVIRONMENT`. An explicit `nil`
    # means no overlay, whatever the variable holds.
    FROM_ENV = :from_env

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

    # Boots a domain directory. See `Runtime::Loader.boot`.
    #
    # @param path [String] path to a domain directory, or a file inside one
    # @param shared [String, nil] a shared-root override
    # @param install_driving [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil, Symbol] the overlay, or `FROM_ENV` for `HECKS_ENVIRONMENT`
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
    def boot(path, shared: nil, install_driving: true, environment: FROM_ENV)
      drive(Runtime::Loader.boot(path, shared: shared, environment: selected_environment(environment)),
            install_driving)
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
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
    def boot_described(described, install_driving: true)
      drive(Runtime::Loader.boot_described(described), install_driving)
    end

    # Boots exactly the named files. See `Runtime::Loader.boot_files`.
    #
    # @param paths [String, Array<String>] one or more file paths within the domain
    # @param shared [String, nil] a shared-root override
    # @param install_driving [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil, Symbol] the overlay, or `FROM_ENV` for `HECKS_ENVIRONMENT`
    # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
    def boot_files(paths, shared: nil, install_driving: true, environment: FROM_ENV)
      drive(Runtime::Loader.boot_files(paths, shared: shared, environment: selected_environment(environment)),
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

    # The dispatcher, with the Ruby driving adapter installed over it when asked.
    def drive(dispatcher, install_driving) = install_driving ? bind_runtime(dispatcher) : dispatcher
    private_class_method :drive
  end
end
