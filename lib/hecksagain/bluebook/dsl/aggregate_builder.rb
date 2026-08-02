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
        def identified_by(field = nil, &path)
          declared = path ? Ports::Extraction.canonical(path) : field
          paths    = declared.to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end

        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          @reference_targets << target
          attribute(as || :"#{Naming.snake(target)}_id", IR::Reference.new(target))
        end

        # `has_many`, `has_one`, `belongs_to` — relationship vocabulary Hecks
        # already grew (README's cherry-pick note) and Rust's parser already
        # read, but this Ruby never declared: a bluebook using one parsed on
        # ONE SIDE ONLY. All three are sugar over `reference_to`, differing
        # from its default only in the attribute name they mint : no `_id`
        # suffix (matching Hecks and Rust's own reading of them, not
        # `reference_to`'s own `_id` mint), and `has_many`'s target is the
        # SINGULAR of what was written (`has_many Invoices` points at Invoice).
        #
        # `has_many` keeps Rust's EXISTING shape — a single reference, not a
        # list. `list_of(Reference<X>)` has no precedent anywhere in this IR :
        # `list_of` is checked everywhere as a list of VALUE OBJECTS
        # (bin/ir_structs, ir_json, both dispatchers' mutation and read
        # paths). A real one-to-many is a separate arc, not a rename of what
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
        # it wrote into nothing, refused nothing, and both runtimes agreed.
        # A DEFAULT FILLS THE SHAPE IT IS DECLARED ON, or it fills nothing.
        #
        # `attribute :cover, one_of("covered", "open"), default: "open"` builds
        # cleanly and then refuses EVERY create at dispatch — "cover is a Cover,
        # pass its fields as an object" — because the value object wants its
        # fields and got a bare string. The bluebook is wrong at the line where
        # it is written and says so nowhere near it.
        #
        # It cost a corpus member 33 refusals out of 40 steps, and `bin/parity`
        # reported AGREED throughout: both runtimes refused identically, which is
        # agreement about nothing. `till.bluebook` has always had the right shape
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

      end
    end
  end
end
