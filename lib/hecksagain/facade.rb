module Hecksagain
  # The class-free public surface — see facade/surface.rb for the door and
  # facade/handle.rb for the record in hand. Installed per boot by
  # `Runtime::Loader.bind_runtime`.
  module Facade
  end

  # The one careful way to put something at top level.
  #
  # Overwrites only what it itself installed (tracked in GENERATED), refuses —
  # with a warning, never a raise — to clobber a constant belonging to user
  # code or the stdlib. Which is why a chapter named `Set` never becomes a
  # constant, and why `Registry` keeps its own table of chapters rather than
  # trusting Ruby's. Each re-install REPLACES the previous boot's entry, so
  # what GENERATED retains is one small facade module per name, not a graph
  # per boot.
  module Namespace
    GENERATED = {}

    module_function

    def install(container, name, value)
      name = name.to_s

      if container.const_defined?(name, false)
        current = container.const_get(name)
        unless GENERATED[[container, name]].equal?(current)
          warn "[hecksagain] #{name} is already defined — leaving it alone"
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
