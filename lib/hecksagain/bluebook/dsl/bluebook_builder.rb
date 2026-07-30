module Hecksagain
  module Bluebook
    module DSL
      class BluebookBuilder
        attr_reader :classification

        def initialize(name, version: nil)
          @name       = name
          @version    = version
          @aggregates       = []
          @read_models      = []
          @policies         = []
          @process_managers = []
        end

        def vision(value)
          # moved to the language: Vision invariant, on Chapter.Declare

          @vision = value
        end

        def core       = @classification = :core
        def supporting = @classification = :supporting
        def generic    = @classification = :generic

        def aggregate(name, &block)
          @aggregates << AggregateBuilder.build(name, &block)
        end

        def read_model(name, &block)
          # A read model gathers heads from SEVERAL aggregates, so no single head
          # declares it — the chapter does. Its owner is stamped in `build`, where
          # the chapter namespace exists.
          @read_models << ReadModelBuilder.build(name, &block)
        end

        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        def process_manager(name, &block)
          @process_managers << ProcessManagerBuilder.build(name, &block)
        end

        def build
          # moved to the language: an attribute type is a reference to its Shape,
          # so an undeclared value object fails reference resolution
          validate_reference_value_objects!
          policies = @aggregates.flat_map(&:policies) + @policies

          bluebook = IR::Bluebook.new(name: @name, version: @version, vision: @vision,
                                      aggregates: @aggregates,
                                      read_models: @read_models,
                                      policies: policies,
                                      process_managers: @process_managers,
                                      classification: @classification)
          namespace = Module.new
          # The chapter is the top of the construct chain — it owns nothing above
          # it, and every `hecks_fqn` below resolves by walking up to here.
          namespace.extend(Construct)
          namespace.hecks_name = @name
          namespace.hecks_root = true

          # A read model is declared by the CHAPTER, not by any one head, so its
          # identity hangs off the chapter: "Pizzas.PizzaWithToppings".
          @read_models.each { |model| model.hecks_owner = namespace }

          @aggregates.each do |aggregate|
            aggregate.ruby_class.domain = @name
            aggregate.ruby_class.hecks_owner = namespace
            namespace.const_set(aggregate.hecks_name, aggregate.ruby_class)
          end

          namespace.define_singleton_method(:vision)     { bluebook.vision }
          namespace.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

          Namespace.install(Object, @name, namespace)
          @aggregates.each do |aggregate|
            next if aggregate.hecks_name == @name

            Namespace.install(Object, aggregate.hecks_name, aggregate.ruby_class)
          end

          # The language judges the bluebook, in the language. Last, so the
          # meta-domain sees a fully built IR — the whole-document rules need
          # every declaration present, which is why they cannot be givens fired
          # at declaration time.
          MetaValidator.call(bluebook)
        end

        private

        def validate_reference_value_objects!
          targets = @aggregates.each_with_object({}) do |aggregate, index|
            index[aggregate.hecks_name] = aggregate
          end
          violations = []

          @aggregates.each do |aggregate|
            aggregate.reference_targets.each { |target| validate_reference(aggregate.hecks_name, target, targets, violations) }
            validate_attribute_references(aggregate.hecks_name, aggregate.attributes, targets, violations)
            aggregate.commands.each do |command|
              validate_reference("#{aggregate.hecks_name}.#{command.hecks_name}", command.references, targets, violations) if command.references
              validate_attribute_references("#{aggregate.hecks_name}.#{command.hecks_name}", command.attributes, targets, violations)
            end
            aggregate.entities.each do |entity|
              validate_attribute_references("#{aggregate.hecks_name}.#{entity.hecks_name}", entity.attributes, targets, violations)
              entity.commands.each do |command|
                validate_reference("#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}", command.references, targets, violations) if command.references
                validate_attribute_references("#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}", command.attributes, targets, violations)
              end
            end
          end

          return if violations.empty?

          raise Malformed, "references must target aggregate heads; #{violations.uniq.join('; ')}"
        end

        def validate_attribute_references(source, attributes, targets, violations)
          attributes.select(&:reference?).each do |attribute|
            validate_reference(source, attribute.type.target_name, targets, violations)
          end
        end

        def validate_reference(source, target_name, targets, violations)
          target = targets[target_name.to_s]
          unless target
            violations << "#{source} references #{target_name}; references may only target aggregate heads"
            return
          end

        end

        def self.build(name, version: nil, &block)
          builder  = new(name, version: version)
          # A bare constant in a bluebook — `attribute :name, PizzaName` — is a NAME,
          # not a reference to something Ruby has heard of. `const_missing` hands
          # over the symbol, and that is the whole answer: `IR::Attribute` spells it
          # with `to_s`, so the `IR::TypeName` wrapper this used to build existed
          # only long enough to be stringified. The concept still has a home — the
          # language declares `value_object "TypeName"` — it just needed no Ruby
          # class of its own.
          resolver = ->(const) { const }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
