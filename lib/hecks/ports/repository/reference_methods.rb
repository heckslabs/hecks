module Hecks
  module Persistence
    # Hecks::Persistence::ReferenceMethods
    #
    # Binds reference resolution methods onto aggregate classes during application
    # boot. For each reference declared on the aggregate, defines a method that
    # resolves the referenced aggregate. The domain works with role names (e.g.,
    # `order.pizza`) — if the stored value is a String ID, it hydrates to the
    # live object; if it's already an object, returns it directly.
    #
    # == Usage
    #
    #   ReferenceMethods.bind(PlayerClass, player_aggregate)
    #   player.team       # => Team instance (hydrated from stored ID or object)
    #
    module ReferenceMethods
      # Defines reference resolution methods on the given aggregate class.
      #
      # @param klass [Class] the aggregate class to augment
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the domain model metadata
      # @return [void]
      def self.bind(klass, aggregate)
        domain_mod = klass.name.split("::")[0..-2].inject(Object) { |m, c| m.const_get(c) }

        (aggregate.references || []).each do |ref|
          method_name = ref.name
          ref_type = ref.type.to_s
          mod = domain_mod

          klass.define_method(method_name) do
            val = instance_variable_get(:"@#{method_name}")
            return nil unless val
            return val unless val.is_a?(String)
            begin; mod.const_get(ref_type).find(val); rescue NameError; nil; end
          end
        end
      end
      end
  end
end
