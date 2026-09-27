module Hecks
  # The class-free public surface, installed per boot by `Runtime::Loader.bind_runtime`.
  module Facade
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
        unless GENERATED[[container, name]].equal?(current)
          warn "[hecks] #{name} is already defined — leaving it alone"
          return current
        end
        container.send(:remove_const, name)
      end

      container.const_set(name, value)
      GENERATED[[container, name]] = value
      value
    end
  end
end

require_relative "facade/handle"
require_relative "facade/surface"
require_relative "facade/command_request"
require_relative "facade/json_door"
