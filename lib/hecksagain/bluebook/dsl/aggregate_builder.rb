module Hecksagain
  module Bluebook
    module DSL
      class AggregateBuilder
        include AttributeCollector

        def initialize(name)
          @name          = name
          @value_objects = []
          @commands      = []
          @identity_paths = []
          @entities      = []
          @queries       = []
          @policies      = []
          @reference_targets = []
        end

        def description(value)
          # moved to the language: Description invariant, on Root.Declare

          @description = value
        end

        # WHICH UNCHANGING FACTS SAY WHICH ONE THIS IS — FIELDS, not whole value
        # objects. `identified_by { number.value }` names the scalar inside
        # AccountNumber ; an identity is a value, and serialising a value object
        # into one only worked while something downstream guessed at `values.first`.
        # Nothing guesses now.
        #
        # SEVERAL PATHS, and the identity is their JOIN, in declaration order :
        #
        #   identified_by do
        #     aggregate_id
        #     name.value
        #   end                        ->  "Pizzas::Order:PlaceOrder"
        #
        # One path is the ordinary case and reads exactly as it always did. More
        # than one is what a thing named BENEATH another needs : a command is not
        # named by `PlaceOrder`, which every chapter may spell, but by the
        # aggregate it belongs to AND that name. Nothing here is minted, so the
        # same declaration names the same record on every run.
        #
        # The block is never CALLED. Its source is read the same way a given's is
        # (Ports::Extraction), which is why `number.value` needs no method called
        # `number` to exist — the same reason `balance >= amount` works in a given.
        # The canonical form collapses the block's newlines to single spaces, so
        # the paths arrive here already separated and in the order written.
        def identified_by(&path)
          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end

        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          @reference_targets << target
          attribute(as || :"#{Naming.snake(target)}_id", IR::Reference.new(target))
        end

        # `has_many`, `has_one`, `belongs_to` — relationship vocabulary Hecks
        # already grew (README's cherry-pick note) but this DSL never
        # declared: a bluebook using one simply failed to load here. All
        # three are sugar over `reference_to`, differing
        # from its default only in the attribute name they mint : no `_id`
        # suffix (matching Hecks' own reading of them, not
        # `reference_to`'s own `_id` mint), and `has_many`'s target is the
        # SINGULAR of what was written (`has_many Invoices` points at Invoice).
        #
        # `has_many` keeps the EXISTING shape — a single reference, not a
        # list. `list_of(Reference<X>)` has no precedent anywhere in this IR :
        # `list_of` is checked everywhere as a list of VALUE OBJECTS
        # (the mutation and read paths alike). A real one-to-many is a
        # separate arc, not a rename of what
        # already parses.
        def has_many(type, as: nil)
          plural = Naming.demodulise(type)
          reference_to(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym)
        end

        def has_one(type, as: nil)
          reference_to(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym)
        end

        def belongs_to(type, as: nil) = has_one(type, as: as)

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def entity(name, &block)
          # A piece is declared IN this aggregate — its owner is stamped by
          # `IR::Aggregate#initialize`, once the aggregate exists. Its own
          # commands were given the piece as their owner when it was declared,
          # so the chain closes as chapter -> aggregate -> entity -> command.
          @entities << EntityBuilder.build(name, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, &block)
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
          # The verb is declared ON this aggregate — the owner `acts_on` answers
          # with — stamped by `IR::Aggregate#initialize` once the aggregate
          # exists. An ENTITY's commands take the entity as their owner instead,
          # at the entity's own declaration.
          @commands << CommandBuilder.build(name, owner: @name, &block)
        end

        def build
          seal_mutation_targets
          seal_query_targets
          seal_defaults

          ir = IR::Aggregate.new(
            name:          @name,
            description:   @description,
            attributes:    attributes,
            value_objects: @value_objects + closed_sets,
            commands:      @commands,
            identified_by: @identity_paths,
            lifecycle:     @lifecycle,
            entities:      @entities,
            queries:       @queries,
            policies:      @policies,
            reference_targets: @reference_targets
          )

          # After the IR exists, on purpose : a reference is declared IN the
          # aggregate, and the aggregate the IR graph knows is `ir`, not the
          # builder.
          stamp_references(ir)
          ir
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # Every reference is told which IR::Aggregate declares it, so it can
        # find the chapter and resolve its target.
        #
        # Stamped HERE, at build, rather than at `reference_to`, because a command
        # builder does not hold the aggregate and should not learn to. And
        # deliberately across every list that can carry one — a reference the walk
        # missed would resolve to nil, and `resolve_references` SKIPS a nil target,
        # so the guarantee would go quiet instead of going red. That is the exact
        # shape of the bug that let an Account belong to an unregistered customer
        # fourteen times over.
        def stamp_references(ir)
          reference_bearing_attributes.each { |attribute| attribute.type.declared_in = ir }
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
        # it wrote into nothing, refused nothing, and every check stayed green.
        # A DEFAULT FILLS THE SHAPE IT IS DECLARED ON, or it fills nothing.
        #
        # `attribute :cover, one_of("covered", "open"), default: "open"` builds
        # cleanly and then refuses EVERY create at dispatch — "cover is a Cover,
        # pass its fields as an object" — because the value object wants its
        # fields and got a bare string. The bluebook is wrong at the line where
        # it is written and says so nowhere near it.
        #
        # It cost a corpus member 33 refusals out of 40 steps, with every gate
        # green throughout: the refusals were perfectly consistent, which is
        # consistency about nothing. `till.bluebook` has always had the right shape
        # — `default: { cents: 0 }`.
        #
        # A PRIMITIVE takes a scalar and a VALUE OBJECT takes its fields, so the
        # test is simply which one the type names. Nothing here guesses at the
        # keys: a default that is a Hash is left to `Value.for_attribute`, which
        # is where a wrong FIELD belongs.
        def seal_defaults
          shapes = @value_objects.map { |shape| shape.hecks_name.to_s }

          attributes.each do |attribute|
            next if attribute.default.nil? || attribute.default.is_a?(Hash)
            next unless shapes.include?(attribute.type.to_s)

            raise Malformed,
                  "#{@name}.#{attribute.name} defaults to #{attribute.default.inspect}, but " \
                  "#{attribute.type} is a value object — a default fills its FIELDS " \
                  "(default: { ... }), and a bare value refuses every create instead"
          end
        end

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

        # A query must ask about a field the aggregate actually HAS — the same
        # seal `then_set` gets, closing the same silence: a where over a field
        # nothing declares matches nothing and refuses nothing, forever, on
        # every adapter. Three more silences close with it. A dotted path may
        # reach through the value-object graph but must LAND on a scalar
        # member (QuerySpecification::FieldPath is the one walk every engine
        # now shares) — landing on a value object hands SQL a JSON object
        # where the reference interpreter unwraps a hash. An ordered
        # comparator (lt/gt/gte/lte) must land on a numeric leaf — over text
        # the reference interpreter quietly matches no rows while SQL
        # compares lexicographically. And a :symbol value must name one of
        # the query's own declared arguments, or it resolves to nil at
        # dispatch and matches nothing.
        ORDERED_COMPARATORS = %i[lt lte gt gte].freeze

        def seal_query_targets
          query_surfaces.each do |owner, fields, lifecycle, queries|
            queries.each do |query|
              query.wheres.each do |clause|
                seal_query_field(owner, query, fields, lifecycle, clause.field)
                seal_ordered_comparator(owner, query, fields, clause)
                seal_query_argument(owner, query, clause.value)
              end
              seal_query_field(owner, query, fields, lifecycle, query.order_by.field) if query.order_by
              seal_query_argument(owner, query, query.limit&.value)
              seal_query_argument(owner, query, query.offset&.value)
            end
          end
        end

        def query_surfaces
          [[@name, attributes, @lifecycle, @queries]] +
            @entities.map { |entity| ["#{@name}::#{entity.hecks_name}", entity.attributes, entity.lifecycle, entity.queries] }
        end

        def seal_query_field(owner, query, fields, lifecycle, field)
          name, *nested = field.to_s.split(".")
          attribute = fields.find { |candidate| candidate.name.to_s == name }
          return if nested.empty? && (attribute || lifecycle&.field.to_s == name)
          return if nested.any? && attribute && scalar_path?(attribute, nested)

          if nested.any? && attribute && resolves?(attribute, nested)
            raise Malformed,
                  "#{owner}.#{query.hecks_name} asks about #{field}, which lands on a " \
                  "value object, not a scalar — a dotted query path ends on a scalar " \
                  "member, or the engines answer it differently"
          end

          raise Malformed,
                "#{owner}.#{query.hecks_name} asks about #{field}, which #{owner} " \
                "never declares — a query over a field that does not exist " \
                "matches nothing and refuses nothing"
        end

        def seal_ordered_comparator(owner, query, fields, clause)
          return unless ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)

          name, *nested = clause.field.to_s.split(".")
          attribute = fields.find { |candidate| candidate.name.to_s == name }
          return if attribute &&
                    QuerySpecification::FieldPath.numeric?(attribute, nested) { |type| declared_value_object(type) }

          held = attribute ? "holds no number" : "is the lifecycle field, which holds text"
          raise Malformed,
                "#{owner}.#{query.hecks_name} compares #{clause.field} with #{clause.op}, " \
                "but #{clause.field} #{held} — an ordered comparison needs a numeric " \
                "field, and over anything else the adapters answer differently or not at all"
        end

        def seal_query_argument(owner, query, value)
          return unless value.is_a?(Symbol)
          return if query.attribute(value)

          raise Malformed,
                "#{owner}.#{query.hecks_name} resolves :#{value} from its arguments, " \
                "but declares no #{value} attribute — an argument that does not exist " \
                "resolves to nil and matches nothing"
        end

        def scalar_path?(attribute, nested)
          QuerySpecification::FieldPath.scalar_leaf?(attribute, nested) { |type| declared_value_object(type) }
        end

        def resolves?(attribute, nested)
          !QuerySpecification::FieldPath.leaf_attribute(attribute, nested) { |type| declared_value_object(type) }.nil?
        end

        def declared_value_object(type_name)
          (@value_objects + closed_sets).find { |shape| shape.hecks_name.to_s == type_name }
        end

      end
    end
  end
end
