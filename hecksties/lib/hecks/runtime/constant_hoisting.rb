# Hecks::Runtime::ConstantHoisting
#
# Promotes aggregate classes to top-level Object constants.
# Defines unload! on the domain module for clean teardown.
#
module Hecks
  class Runtime
    # Hecks::Runtime::ConstantHoisting
    #
    # Promotes aggregate classes to top-level Object constants and defines unload! for clean teardown.
    #
      module ConstantHoisting
        private

        def hoist_constants
          hoisted = []
          @domain.aggregates.each do |agg|
            name = agg.name.to_sym
            klass = @mod.const_get(agg.name)
            Hecks::Utils.remove_constant(name) if Object.const_defined?(name, false)
            Object.const_set(name, klass)
            hoisted << name
          end

          mod = @mod
          mod_name = @mod.name.to_sym
          mod.define_singleton_method(:unload!) do
            hoisted.each { |name| Hecks::Utils.remove_constant(name) }
            Hecks::Utils.remove_constant(mod_name)
          end
        end
      end
  end
end
