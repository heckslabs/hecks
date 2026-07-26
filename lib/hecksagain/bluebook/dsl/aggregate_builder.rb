# AggregateBuilder — evaluates an `aggregate "Pizza" do ... end` block, and
# CONSTRUCTS the Ruby class while it reads.
#
# One pass, two products: the IR (for export, and for whatever target reads it)
# and a real Ruby class (for the developer). Both come from reading the source.
# The IR is never read back to make the class — that would make Ruby a
# projection of itself.
#
#   aggregate "Pizza" do          # -> class Pizzas::Pizza < Hecksagain::Aggregate
#     attribute :toppings, ...    # -> def toppings
#     command "AddTopping" do     # -> def add_topping(**args)
#     command "CreatePizza" do    # -> def self.create_pizza(**args)
#   end
module Hecksagain
  module Bluebook
    module DSL
      class AggregateBuilder
        include AttributeCollector

        # Names the base class already uses. An attribute may not shadow them —
        # a domain attribute called `state` would break the very thing that
        # stores it.
        RESERVED = %i[id state events reload inspect to_h hash class].freeze

        def initialize(name)
          @name          = name
          @value_objects = []
          @commands      = []
          @identified_by = :id
          @klass         = Class.new(Aggregate)
        end

        def description(value)   = @description = value
        def identified_by(field) = @identified_by = field.to_sym

        # Another root, referenced by its global identity.
        #
        # The BARE name — see CommandBuilder#reference_to for why a fully
        # qualified one would silently point across domains.
        def reference_to(type)
          attribute(:"#{Naming.snake(Naming.demodulise(type))}_id", String)
        end

        # A state machine on one of this aggregate's fields. Brought over
        # from Hecks unchanged — same signature, same block body — so a
        # bluebook written there reads here without an edit.
        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def value_object(name, &block)
          @value_objects << ValueObjectBuilder.build(name, &block)
        end

        # Read the command, keep its IR, and define the method it describes.
        def command(name, &block)
          command = CommandBuilder.build(name, &block)
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
            lifecycle:     @lifecycle
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
        end

        # A creating command mints identity, so it belongs to the class. Any
        # other command already knows its instance, so it belongs to the object
        # and never asks for an id.
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
