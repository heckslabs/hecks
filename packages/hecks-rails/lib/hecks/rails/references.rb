module Hecks
  module Rails
    # `transfer.source_account`: the record a reference names, looked up only when asked for.
    #
    # A reference attribute holds its target's identity, never a loaded record, so nothing loads
    # until a lookup is called. The lookup is named for the attribute and its target
    # (`source_account`), or `account_record` when the attribute is named for its target, so the
    # raw identity under `account` stays reachable. It answers the target's model, which is the
    # app's own class when it wrote one and the generated skin otherwise.
    module References
      module_function

      # Defines a lookup for each reference attribute of an aggregate, in a module of the model's
      # own so the app can override one by name and call `super`.
      #
      # @param model [Class] a `Hecks::Rails::Model` subclass
      # @param aggregate [Hecks::Bluebook::Aggregate] the aggregate it stands for
      # @return [void]
      def define(model, aggregate)
        mod = lookups(model)
        aggregate.attributes.select(&:reference?).each do |attribute|
          target = attribute.target_aggregate
          mod.define_method(lookup_name(attribute, target)) { References.find(attribute, target, to_h) } if target
        end
      end

      # @param attribute [Hecks::Bluebook::Attribute] a reference attribute
      # @param target [Hecks::Bluebook::Aggregate] the aggregate it refers to
      # @return [String] the lookup's method name
      def lookup_name(attribute, target)
        noun = Naming.snake(target.hecks_name).to_s
        attribute.name.to_s == noun ? "#{noun}_record" : "#{attribute.name}_#{noun}"
      end

      # @param attribute [Hecks::Bluebook::Attribute] the reference attribute
      # @param target [Hecks::Bluebook::Aggregate] the aggregate it refers to
      # @param fields [Hash{Symbol => Object}] the referring record's fields
      # @return [Model, Array<Model>, nil] the referenced record (each one for a list); nil when
      #   the reference is unset
      # @raise [Model::RecordNotFound] when a named record is not stored
      def find(attribute, target, fields)
        model = Object.const_get(target.hecks_name)
        value = fields[attribute.name.to_sym]
        return Array(value).map { |identity| model.find(identity) } if attribute.list?

        value && model.find(value)
      end

      # The module holding a model's lookups, made once and included.
      def lookups(model)
        return model.const_get(:Lookups, false) if model.const_defined?(:Lookups, false)

        model.const_set(:Lookups, Module.new).tap { |mod| model.include(mod) }
      end
    end
  end
end
