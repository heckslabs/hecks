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

        # A reaction that belongs to the DOMAIN rather than to one aggregate
        # — the event and the command it triggers live in different
        # boundaries, so neither root owns the rule.
        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        # A conversation across several events, correlated to one instance
        # and carrying its own state. Always domain-level : no single
        # aggregate is its subject.
        def process_manager(name, &block)
          @process_managers << ProcessManagerBuilder.build(name, &block)
        end

        def build
          # Aggregate-nested policies BUBBLE to the domain. A policy names an
          # event and a command that may live in different boundaries, so no
          # single root owns it — declaring it inside an aggregate says where
          # the causality was noticed, not who keeps the rule. The interpreter
          # holds them domain-level only, and this is where the two agree.
          policies = @policies + @aggregates.flat_map(&:policies)

          bluebook = IR::Bluebook.new(name: @name, vision: @vision,
                                      aggregates: @aggregates,
                                      policies: policies,
                                      process_managers: @process_managers)
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
end
