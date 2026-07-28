module Hecksagain
  module Bluebook
    module DSL
      class BluebookBuilder
        attr_reader :classification

        def initialize(name)
          @name       = name
          @aggregates       = []
          @policies         = []
          @process_managers = []
        end

        def vision(value)
          raise Malformed, "#{@name}'s vision says nothing" if value.to_s.empty?

          @vision = value
        end

        def core       = @classification = :core
        def supporting = @classification = :supporting
        def generic    = @classification = :generic

        def aggregate(name, &block)
          @aggregates << AggregateBuilder.build(name, &block)
        end

        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        def process_manager(name, &block)
          @process_managers << ProcessManagerBuilder.build(name, &block)
        end

        def build
          policies = @aggregates.flat_map(&:policies) + @policies

          bluebook = IR::Bluebook.new(name: @name, vision: @vision,
                                      aggregates: @aggregates,
                                      policies: policies,
                                      process_managers: @process_managers,
                                      classification: @classification)
          namespace = Module.new

          @aggregates.each do |aggregate|
            aggregate.ruby_class.domain = @name
            namespace.const_set(aggregate.name, aggregate.ruby_class)
          end

          namespace.define_singleton_method(:vision)     { bluebook.vision }
          namespace.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

          Namespace.install(Object, @name, namespace)
          @aggregates.each do |aggregate|
            next if aggregate.name == @name

            Namespace.install(Object, aggregate.name, aggregate.ruby_class)
          end

          bluebook
        end

        def self.build(name, &block)
          builder  = new(name)
          resolver = ->(const) { IR::TypeName.new(const) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
