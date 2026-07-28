module Hecksagain
  module Bluebook
    module DSL
      class AggregateBuilder
        include AttributeCollector

        RESERVED = %i[id state events reload inspect to_h hash class].freeze

        def initialize(name)
          @name          = name
          @value_objects = []
          @commands      = []
          @identified_by = :id
          @entities      = []
          @queries       = []
          @policies      = []
          @klass         = Class.new(Aggregate)
        end

        def description(value)
          raise Malformed, "#{@name}'s description says nothing" if value.to_s.empty?

          @description = value
        end

        def identified_by(field)
          raise Malformed, "#{@name}.identified_by names no field" if field.to_s.empty?

          @identified_by = field.to_sym
        end

        def reference_to(type)
          attribute(:"#{Naming.snake(Naming.demodulise(type))}_id", String)
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def entity(name, &block)
          @entities << EntityBuilder.build(name, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, &block)
        end

        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        def value_object(name, &block)
          @value_objects << ValueObjectBuilder.build(name, &block)
        end

        def command(name, &block)
          command = CommandBuilder.build(name, owner: @name, &block)
          @commands << command
          define_command(command)
        end

        def build
          ir = IR::Aggregate.new(
            name:          @name,
            description:   @description,
            attributes:    attributes,
            value_objects: @value_objects,
            commands:      @commands,
            identified_by: @identified_by,
            lifecycle:     @lifecycle,
            entities:      @entities,
            queries:       @queries,
            policies:      @policies
          )

          @klass.ir     = ir
          ir.ruby_class = @klass
          define_readers
          ir
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def define_readers
          attributes.each do |attribute|
            if RESERVED.include?(attribute.name)
              warn "[hecksagain] #{@name}##{attribute.name} shadows a built-in — no reader defined"
              next
            end

            field = attribute.name
            @klass.define_method(field) { @state[field] }
          end

          if @lifecycle && !RESERVED.include?(@lifecycle.field)
            field = @lifecycle.field
            @klass.define_method(field) { @state[field] }
          end
        end

        def define_command(command)
          method_name = Naming.snake(command.name)
          verb        = command.name

          if command.creates?
            @klass.define_singleton_method(method_name) do |**args|
              wrap(run(verb, **args).instance)
            end
          else
            @klass.define_method(method_name) do |**args|
              run(verb, **args)
            end
          end
        end
      end
    end
  end
end
