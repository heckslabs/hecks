# BluebookBuilder — evaluates a `Hecks.bluebook "Pizzas" do ... end` block.
#
# The classification keywords (core / supporting / generic) are Evans' strategic
# distinctions. They are recorded, not enforced — they tell a reader where to
# spend attention, and later tell a generator how hard to optimise.
#
#   Hecks.bluebook "Pizzas" do
#     vision "Put toppings on a pizza and sell it to a customer."
#     core
#     aggregate("Pizza") { ... }
#   end
module Hecksagain
  module DSL
    class BluebookBuilder
      attr_reader :classification

      def initialize(name)
        @name       = name
        @aggregates = []
      end

      def vision(value) = @vision = value

      def core       = @classification = :core
      def supporting = @classification = :supporting
      def generic    = @classification = :generic

      def aggregate(name, &block)
        @aggregates << AggregateBuilder.build(name, &block)
      end

      def build
        bluebook = IR::Bluebook.new(name: @name, vision: @vision, aggregates: @aggregates)
        namespace = Module.new

        @aggregates.each do |aggregate|
          aggregate.ruby_class.domain = @name
          namespace.const_set(aggregate.name, aggregate.ruby_class)
        end

        namespace.define_singleton_method(:vision)     { bluebook.vision }
        namespace.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

        # Naming the module names every class inside it (Pizzas::Pizza), and
        # lifting the aggregates to top level is what lets a domain be written
        # as plain Ruby: `Pizza.create_pizza(...)`, not
        # `Pizzas::Pizza.create_pizza(...)`.
        Namespace.install(Object, @name, namespace)
        @aggregates.each do |aggregate|
          # An aggregate sharing its domain's name (Expression::Expression)
          # must not claim the domain's constant — it would leave the domain
          # module unreachable and take its siblings with it.
          next if aggregate.name == @name

          Namespace.install(Object, aggregate.name, aggregate.ruby_class)
        end

        bluebook
      end

      def self.build(name, &block)
        builder  = new(name)
        # Domain types (Name, Topping) are named before they exist — resolve
        # them to TypeName for the duration of this block only.
        resolver = ->(const) { IR::TypeName.new(const) }
        ConstShim.with(resolver) { builder.instance_eval(&block) } if block
        builder.build
      end
    end
  end
end
