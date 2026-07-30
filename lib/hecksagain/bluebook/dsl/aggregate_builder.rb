module Hecksagain
  module Bluebook
    module DSL
      class AggregateBuilder
        include AttributeCollector

        def initialize(name)
          @name          = name
          @value_objects = []
          @commands      = []
          @identified_by = :id
          @entities      = []
          @queries       = []
          @policies      = []
          @reference_targets = []
          @klass         = Class.new(Aggregate)
          @klass.hecks_name = name
        end

        def description(value)
          # moved to the language: Description invariant, on Root.Declare

          @description = value
        end

        def identified_by(field)
          raise Malformed, "#{@name}.identified_by names no field" if field.to_s.empty?

          @identified_by = field.to_sym
        end

        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          @reference_targets << target
          attribute(as || :"#{Naming.snake(target)}_id", IR::Reference.new(target))
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def entity(name, &block)
          piece = EntityBuilder.build(name, &block)
          # A piece is declared IN this aggregate. Its own commands were given the
          # piece as their owner when it was declared, so the chain is now
          # chapter -> aggregate -> entity -> command, and every link can state
          # an identity.
          piece.hecks_owner = @klass
          @entities << piece
        end

        def query(name, &block)
          ask = QueryBuilder.build(name, &block)
          ask.hecks_owner = @klass
          @queries << ask
        end

        def policy(name, &block)
          reaction = PolicyBuilder.build(name, &block)
          reaction.aggregate = @name
          @policies << reaction
        end

        def value_object(name, &block)
          @value_objects << ValueObjectBuilder.build(name, &block)
        end

        def command(name, &block)
          command = CommandBuilder.build(name, owner: @name, &block)
          # The verb is declared ON this aggregate, which is what `acts_on` answers
          # with. An ENTITY's commands are deliberately not stamped here: they are
          # declared on the entity, and an entity is still an IR object rather than
          # a construct, so asking one for its identity refuses rather than
          # answering "Deposit" and looking right.
          command.hecks_owner = @klass
          @commands << command
          define_command(command)
        end

        def build
          seal_mutation_targets
          nest_value_objects
          stamp_references

          ir = IR::Aggregate.new(
            name:          @name,
            description:   @description,
            attributes:    attributes,
            value_objects: @value_objects + closed_sets,
            commands:      @commands,
            identified_by: @identified_by,
            lifecycle:     @lifecycle,
            entities:      @entities,
            queries:       @queries,
            policies:      @policies,
            reference_targets: @reference_targets
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

        # A value object is declared INSIDE an aggregate, so its class is nested
        # inside the aggregate's — `Pizzas::Pizza::Price`. That nesting is what
        # lets two aggregates each declare their own `Money` without collision,
        # which the VO-placement convention deliberately allows.
        #
        # The owner is set as well as the constant, because `hecks_fqn` is
        # computed by walking owners rather than stamped — the chapter above this
        # aggregate does not exist yet, and will not until the whole file is read.
        def nest_value_objects
          (@value_objects + closed_sets).each do |shape|
            shape.hecks_owner = @klass
            name = shape.hecks_name
            @klass.send(:remove_const, name) if @klass.const_defined?(name, false)
            @klass.const_set(name, shape)
          end
        end

        # Every reference is told which aggregate declares it, so it can find the
        # chapter and resolve its target.
        #
        # Stamped HERE, at build, rather than at `reference_to`, because a command
        # builder does not hold the aggregate's class and should not learn to. And
        # deliberately across every list that can carry one — a reference the walk
        # missed would resolve to nil, and `resolve_references` SKIPS a nil target,
        # so the guarantee would go quiet instead of going red. That is the exact
        # shape of the bug that let an Account belong to an unregistered customer
        # fourteen times over.
        def stamp_references
          reference_bearing_attributes.each { |attribute| attribute.type.declared_in = @klass }
        end

        def reference_bearing_attributes
          lists = [attributes, *@commands.map(&:attributes), *@queries.map(&:attributes)]
          @entities.each do |entity|
            lists << entity.attributes
            lists.concat(entity.commands.map(&:attributes))
            lists.concat(entity.queries.map(&:attributes))
          end

          lists.flatten.select(&:reference?)
        end

        # A mutation must name a field the aggregate actually HAS.
        #
        # NOT moved to the language, and deliberately so. The language says only
        # `given("a mutation names a target") { !target.value.to_s.empty? }` —
        # non-emptiness — because saying more means reaching a list that lives on
        # a DIFFERENT root : a command's changes hang off Command, the fields they
        # name hang off Aggregate, and a given is a closed predicate over its own
        # state. Aggregate.Seal is the right shape and cannot see commands ; the
        # reference trick that rescued "attributes use value-object types" needs a
        # root to point at, and an aggregate's fields are a value-object list, not
        # roots. This is the second rule that cannot port for that reason — the
        # first is read-model uniqueness — and both wait on the same thing : a
        # quantifier, or fields promoted to roots.
        #
        # So it lives here, at build, where every declaration is present. Found by
        # writing `then_set :disputed_by` on CardPayment before the field existed :
        # it wrote into nothing, refused nothing, and both runtimes agreed.
        def seal_mutation_targets
          known = attributes.map { |attribute| attribute.name.to_sym }
          known << @lifecycle.field.to_sym if @lifecycle

          @commands.each do |command|
            command.mutations.each do |mutation|
              next if known.include?(mutation.target.to_sym)

              raise Malformed,
                    "#{@name}.#{command.hecks_name} sets #{mutation.target}, which #{@name} " \
                    "never declares — a mutation into a field that does not exist " \
                    "writes nothing and refuses nothing"
            end
          end
        end

        # The class defines its own surface now — `Aggregate.declare_reader` and
        # `.declare_verb`. These used to build the methods here, reaching into
        # @klass from outside, which meant the DSL was the only thing that could
        # ever finish an aggregate. The assembler needs the same two calls.
        def define_readers
          attributes.each { |attribute| @klass.declare_reader(attribute.name) }
          @klass.declare_reader(@lifecycle.field) if @lifecycle
        end

        def define_command(command)
          @klass.declare_verb(command.hecks_name, creates: command.creates?)
        end
      end
    end
  end
end
