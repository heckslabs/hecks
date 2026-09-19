module Hecks
  # The class-free public surface — see facade/surface.rb for the door and
  # facade/handle.rb for the record in hand. Installed per boot by
  # `Runtime::Loader.bind_runtime`.
  module Facade
  end

  # The one careful way to put something at top level.
  #
  # Overwrites only what it itself installed (tracked in `GENERATED`), refuses —
  # with a warning, never a raise — to clobber a constant belonging to user
  # code or the stdlib. Which is why a chapter named `Set` never becomes a
  # constant, and why `Registry` keeps its own table of chapters rather than
  # trusting Ruby's. Each re-install replaces the previous boot's entry, so
  # what `GENERATED` retains is one small facade module per name, not a graph
  # per boot.
  module Namespace
    # Not frozen — a real registry, mutated below
    # (`GENERATED[[container, name]] = value`). False positive for
    # Style/MutableConstant.
    # rubocop:disable-next Style/MutableConstant
    GENERATED = {}

    module_function

    # Sets `container::name` to `value`, replacing only a constant this module installed
    # itself and leaving any other existing constant in place with a warning.
    #
    # @param container [Module] the namespace to define the constant in; every caller in
    #   this repository passes `Object`
    # @param name [String, Symbol] the constant name, such as a chapter or aggregate name
    # @param value [Module] the facade module to install under that name
    # @return [Object] `value` when it was installed; otherwise the constant already
    #   defined under `name`, which this module does not own and did not replace
    # @raise [NameError] if `name` is not a valid constant name (raised by
    #   `const_defined?`)
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
