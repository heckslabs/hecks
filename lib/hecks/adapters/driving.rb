module Hecks
  module Adapters
    # Driving adapters: how an outside caller reaches in. The Ruby one is the class-free public
    # surface, installed per boot by `Runtime::Loader.bind_runtime`.
    module Driving
    end
  end

  # Installs facade constants at top level, replacing only what it installed itself.
  # A constant owned by user code or the stdlib is left alone with a warning.
  module Namespace
    # A live registry, mutated by `install`, so it cannot be frozen.
    # rubocop:disable-next Style/MutableConstant
    GENERATED = {}

    module_function

    # Sets `container::name` to `value`, replacing only a constant this module installed.
    #
    # @param container [Module] the namespace to define the constant in
    # @param name [String, Symbol] the constant name
    # @param value [Module] the facade module to install
    # @return [Object] `value` when installed, else the foreign constant left in place
    # @raise [NameError] if `name` is not a valid constant name
    def install(container, name, value)
      name = name.to_s

      if container.const_defined?(name, false)
        current = container.const_get(name)
        return leave_alone(name, current) unless GENERATED[[container, name]].equal?(current)

        container.send(:remove_const, name)
      end

      container.const_set(name, value)
      GENERATED[[container, name]] = value
      value
    end

    # @param name [String] the constant name
    # @param current [Object] the constant user code or the stdlib owns
    # @return [Object] `current`, after warning that it was left in place
    def leave_alone(name, current)
      warn "[hecks] #{name} is already defined — leaving it alone"
      current
    end
  end
end

require_relative "driving/handle"
require_relative "driving/ruby"
require_relative "driving/command_request"
require_relative "driving/json"
