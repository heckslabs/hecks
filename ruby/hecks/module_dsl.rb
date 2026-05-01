# Hecks::ModuleDSL
#
# Declarative helpers for Hecks module mixins. Provides +lazy_registry+
# to define lazily-initialized registries without manual ivar management.
#
#   module MyRegistryMethods
#     extend Hecks::ModuleDSL
#     lazy_registry :widgets
#     lazy_registry(:rules) { [] }
#   end
#
module Hecks
  # Hecks::ModuleDSL
  #
  # Declarative helpers for module mixins providing lazy_registry for lazily-initialized registries.
  #
  module ModuleDSL
    def lazy_registry(name, private: false, &default)
      default ||= -> { {} }

      define_method(name) do
        key = :"@#{name}"
        return instance_variable_get(key) if instance_variable_defined?(key)
        instance_variable_set(key, default.call)
      end

      private(name) if binding.local_variable_get(:private)
    end
  end
end
