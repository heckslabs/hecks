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

          @aggregates.each do |aggregate|
            aggregate.ruby_class.domain = @name
            aggregate.ruby_class.hecks_owner = namespace
            namespace.const_set(aggregate.name, aggregate.ruby_class)
          end

          namespace.define_singleton_method(:vision)     { bluebook.vision }
          namespace.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

          Namespace.install(Object, @name, namespace)
          @aggregates.each do |aggregate|
            next if aggregate.name == @name

            Namespace.install(Object, aggregate.name, aggregate.ruby_class)
          end

          # The language judges the bluebook, in the language. Last, so the
          # meta-domain sees a fully built IR — the whole-document rules need
          # every declaration present, which is why they cannot be givens fired
          # at declaration time.
          MetaValidator.call(bluebook)
        end

        private

        def validate_value_object_attributes!
          violations = []

          @aggregates.each do |aggregate|
            validate_attributes(aggregate.name, aggregate.attributes, aggregate, violations)
            aggregate.commands.each do |command|
              validate_attributes("#{aggregate.name}.#{command.name}", command.attributes, aggregate, violations)
            end
            aggregate.queries.each do |query|
              validate_attributes("#{aggregate.name}.#{query.name}", query.attributes, aggregate, violations)
            end
            aggregate.entities.each do |entity|
              validate_attributes("#{aggregate.name}.#{entity.name}", entity.attributes, aggregate, violations)
              entity.commands.each do |command|
                validate_attributes("#{aggregate.name}.#{entity.name}.#{command.name}", command.attributes, aggregate, violations)
              end
              entity.queries.each do |query|
                validate_attributes("#{aggregate.name}.#{entity.name}.#{query.name}", query.attributes, aggregate, violations)
              end
            end
          end

          return if violations.empty?

          raise Malformed, "attributes must use value-object types; #{violations.join('; ')}"
        end

        def validate_attributes(owner, attributes, aggregate, violations)
          attributes.each do |attribute|
            next if attribute.reference?
            next if aggregate.value_object(attribute.type)
            next if attribute.list? && aggregate.entities.any? { |entity| entity.name == attribute.type }

            violations << "#{owner}##{attribute.name} is #{attribute.type}, not a value object declared by #{aggregate.name}"
          end
        end

        def validate_reference_value_objects!
          targets = @aggregates.each_with_object({}) do |aggregate, index|
            index[aggregate.name] = aggregate
          end
          violations = []

          @aggregates.each do |aggregate|
            aggregate.reference_targets.each { |target| validate_reference(aggregate.name, target, targets, violations) }
            validate_attribute_references(aggregate.name, aggregate.attributes, targets, violations)
            aggregate.commands.each do |command|
              validate_reference("#{aggregate.name}.#{command.name}", command.references, targets, violations) if command.references
              validate_attribute_references("#{aggregate.name}.#{command.name}", command.attributes, targets, violations)
            end
            aggregate.entities.each do |entity|
              validate_attribute_references("#{aggregate.name}.#{entity.name}", entity.attributes, targets, violations)
              entity.commands.each do |command|
                validate_reference("#{aggregate.name}.#{entity.name}.#{command.name}", command.references, targets, violations) if command.references
                validate_attribute_references("#{aggregate.name}.#{entity.name}.#{command.name}", command.attributes, targets, violations)
              end
            end
          end

          return if violations.empty?

          raise Malformed, "references must target aggregate heads; #{violations.uniq.join('; ')}"
        end

        def validate_attribute_references(source, attributes, targets, violations)
          attributes.select(&:reference?).each do |attribute|
            target = attribute.type.delete_prefix("Reference<").delete_suffix(">")
            validate_reference(source, target, targets, violations)
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
          resolver = ->(const) { IR::TypeName.new(const) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
