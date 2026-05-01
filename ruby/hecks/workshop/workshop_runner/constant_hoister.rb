# Hecks::Workshop::WorkshopRunner::ConstantHoister
#
# Manages hoisting and cleanup of constants on WorkshopRunner.
# Aggregate handles and domain module constants are hoisted so
# users can type `Pizza` instead of `PizzasDomain::Pizza` in the REPL.
#
module Hecks
  class Workshop
    class WorkshopRunner
      module ConstantHoister
        def hoist_aggregate(const_name, handle)
          @hoisted_handle_constants ||= []
          unless self.class.const_defined?(const_name, false)
            self.class.const_set(const_name, handle)
            @hoisted_handle_constants << const_name
          end
        end

        def hoist_domain_constants(mod)
          @hoisted_constants = []
          mod.constants.each do |const_name|
            unless self.class.const_defined?(const_name, false)
              self.class.const_set(const_name, mod.const_get(const_name))
              @hoisted_constants << const_name
            end
          end
        end

        def unhoist_all
          [@hoisted_constants, @hoisted_handle_constants].compact.each do |list|
            list.each { |name| Hecks::Utils.remove_constant(name, from: self.class) }
          end
          @hoisted_constants = nil
          @hoisted_handle_constants = nil
        end
      end
    end
  end
end
