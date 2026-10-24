module Hecks
  module Rails
    class Model
      # Defines a model's readers, verbs and reference lookups from its aggregate's IR.
      #
      # Every method lands in a module of the model's own (`HecksMethods`, and
      # `HecksClassMethods` for the creating verbs), never on the class itself, so an app
      # overrides one by name and calls `super`. A verb answers its IR command under its bare
      # name and dispatches under its bang name, as a core handle does (ADR 0120); a bare name
      # that is a field reader or a method the model already has keeps that meaning.
      module Verbs
        # Object and ActiveModel methods a bare verb name never replaces.
        KEPT = (Adapters::Driving::Handle::VerbMethods::CORE_NAMES +
                %i[freeze frozen? send display errors id to_param to_key to_model model_name]).freeze

        module_function

        # Defines everything the aggregate gives a model class, replacing what an earlier boot
        # defined.
        #
        # @param model [Class] the `Rails::Model` subclass
        # @param address [Rails::BootedDomain::Address] the aggregate it stands for
        # @return [void]
        def define(model, address)
          instance = fresh_module(model, :HecksMethods) { |mod| model.include(mod) }
          singleton = fresh_module(model, :HecksClassMethods) { |mod| model.extend(mod) }
          define_readers(instance, address.aggregate)
          define_references(instance, address.aggregate)
          define_instance_verbs(instance, address.aggregate)
          define_creating_verbs(singleton, address)
        end

        # Turns what a caller passed a bang verb into the facts a dispatch takes.
        #
        # @param args [Hash, nil] the facts, by String or Symbol name
        # @return [Hash{Symbol => Object}] the facts by Symbol name
        def facts(args) = (args || {}).to_h.transform_keys(&:to_sym)

        # The model's module of that name, emptied, or a new one that `attach` hooks onto it.
        def fresh_module(model, name, &)
          if model.const_defined?(name, false)
            mod = model.const_get(name, false)
            mod.instance_methods(false).each { |method| mod.send(:remove_method, method) }
            return mod
          end

          model.const_set(name, Module.new).tap(&)
        end

        # One raw reader per attribute and for the lifecycle field: a reference reads its identity.
        def define_readers(mod, aggregate)
          names = aggregate.attributes.map(&:name) + [aggregate.lifecycle_field].compact
          names.map(&:to_sym).uniq.each do |name|
            mod.define_method(name) { self[name] }
          end
        end

        # `transfer.source_account`: the referenced record, looked up only when called.
        def define_references(mod, aggregate)
          aggregate.attributes.select(&:reference?).each do |attribute|
            target = attribute.target_aggregate
            next unless target

            mod.define_method(lookup_name(attribute, target)) { Lookup.call(self, attribute, target) }
          end
        end

        # `<attribute>_<target>`, or `<attribute>_record` for an attribute named for its target.
        def lookup_name(attribute, target)
          noun = Naming.snake(target.hecks_name)
          attribute.name.to_s == noun ? "#{noun}_record" : "#{attribute.name}_#{noun}"
        end

        def define_instance_verbs(mod, aggregate)
          aggregate.commands.reject(&:creates?).each do |command|
            name = Naming.snake(command.hecks_name)
            mod.define_method("#{name}!") { |args = nil, **kwargs| run(command, Verbs.facts(args).merge(kwargs)) }
            mod.define_method(name) { command } unless kept?(aggregate, name.to_sym)
          end
        end

        def define_creating_verbs(mod, address)
          address.aggregate.commands.select(&:creates?).each do |command|
            name = Naming.snake(command.hecks_name)
            mod.define_method(name) { command }
            mod.define_method("#{name}!") do |args = nil, **kwargs|
              new(Rails.domain.create(address, command, Verbs.facts(args).merge(kwargs)))
            end
          end
        end

        def kept?(aggregate, name)
          KEPT.include?(name) || !aggregate.attribute(name).nil? || aggregate.lifecycle_field&.to_sym == name ||
            Model.method_defined?(name) || Model.private_method_defined?(name)
        end
      end

      # Looks up the record a reference names, as the target's own model when the app declares one.
      module Lookup
        module_function

        # @param record [Rails::Model] the record holding the reference
        # @param attribute [Bluebook::Attribute] the reference attribute
        # @param target [Bluebook::Aggregate] the aggregate it refers to
        # @return [Rails::Model, Array<Rails::Model>, nil] the referenced record, or a list's each;
        #   nil when the reference is unset
        # @raise [Rails::RecordNotFound] if a named record is not stored
        def call(record, attribute, target)
          address = BootedDomain::Address.new(record.class.address.chapter, target)
          model = Model.for(address) || Class.new(Model) { define_singleton_method(:address) { address } }
          value = record[attribute.name]
          return Array(value).map { |identity| model.find(identity) } if attribute.list?

          value && model.find(value)
        end
      end
    end
  end
end
