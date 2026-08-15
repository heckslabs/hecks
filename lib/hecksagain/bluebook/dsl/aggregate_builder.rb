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

        # ORIGIN, not runtime identity — a concept adopted from a canonical
        # source (§28) names where it came from without that fact ever
        # touching `hecks_fqn`/dispatch. Captured raw, the same way
        # `attribute ..., default: { value: "small" }` captures a literal
        # Hash untouched — no re-parsing, no structure imposed beyond
        # "whatever the author wrote."
        def provenance(from:)
          @provenance = from
        end

        # WHICH UNCHANGING FACTS SAY WHICH ONE THIS IS — a declared field,
        # never a minted one (ADR 0025, "Identity"). `identified_by :number`
        # points at an attribute already declared on its own line ; the
        # type used to be spelled here too (`identified_by AccountNumber,
        # as: :number`) ONLY because that was the one place minting it, and
        # minting is gone — `attribute :number, AccountNumber` says it once,
        # where every other attribute does.
        #
        # SEVERAL FIELDS, and the identity is their JOIN, in declaration
        # order — composite identity is `identified_by :branch_code,
        # :box_number`, not a block. A single-field value object auto-
        # unwraps to its own member (`identified_by :number` derives
        # "number.value" when `Number` has exactly one field) ; a bare
        # scalar or a reference resolves to its own name unchanged — see
        # `AttributeCollector#resolve_identity_field!`, shared with
        # `EntityBuilder`.
        def identified_by(*targets, as: nil, &path)
          return legacy_identified_by(targets.first, as: as, &path) if MetaValidator.shadow_parsing?

          raise Malformed,
                "#{@name}.identified_by no longer takes a block — write identified_by :field, " \
                "or identified_by :field_one, :field_two for a composite identity" if path
          raise Malformed, "#{@name}.identified_by names no field" if targets.empty?

          # A bareword constant (`PizzaName`) and a quoted field name
          # (`:name`) are BOTH plain Ruby Symbols/ScopedConstants by the
          # time they reach here — distinguished the same way the language
          # already reads everywhere else: a value object is PascalCase, a
          # field is snake_case.
          if targets.size == 1 && targets.first.to_s[0] =~ /[A-Z]/
            field = as || Naming.snake(targets.first)
            raise Malformed,
                  "#{@name}.identified_by no longer takes a value object — declare the attribute " \
                  "first (attribute :#{field}, #{targets.first}) and write identified_by :#{field}"
          end

          raise Malformed, "#{@name}.identified_by takes no as: — name the declared field itself" if as

          @identity_fields_pending = targets
        end

        # `optional:` — matching `CommandBuilder#reference_to`'s own
        # signature, which already had it; this one never forwarded it
        # to `attribute()` even though `attribute()` itself already
        # accepts it. A real gap: an aggregate that can point at ONE OF
        # several targets (Item's own `personal_list_id`/
        # `camping_list_id`, never both) needs each reference optional
        # on the aggregate's own persisted schema, not just as a
        # command's input.
        def reference_to(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          @reference_targets << target
          attribute(as || default_reference_name(target), Reference.new(target), optional: optional)
        end

        # `has_many`, `has_one`, `belongs_to` — LEGACY (ADR 0025,
        # "References"): all three were sugar over `reference_to`,
        # differing from its default only in the attribute name they
        # minted — no `_id` suffix. `reference_to` mints that same bare
        # name now (`default_reference_name`, `AttributeCollector`'s own
        # comment), so the three have no work left; `reference_to` alone
        # says everything they did. `has_many` additionally LIED — it
        # singularised its target and minted one scalar, so `film.backers`
        # read `nil` and never `[]` — one more reason it earns no live
        # replacement, in addition to `reference_to` already covering it.
        # Kept here, refusing live, ONLY so `MetaValidator.shadow_parsing?`
        # (S0a's own bridge) can still make sense of frozen era text that
        # used one — real, if rare: "Combined corpus uses: one."
        def has_many(type, as: nil, optional: false)
          return legacy_has_many(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          raise Malformed,
                "#{@name}.has_many is gone — reference_to #{Naming.singularize(Naming.demodulise(type))} " \
                "mints the same bare name now"
        end

        def has_one(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          raise Malformed, "#{@name}.has_one is gone — reference_to #{Naming.demodulise(type)} mints the same bare name now"
        end

        def belongs_to(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          raise Malformed, "#{@name}.belongs_to is gone — reference_to #{Naming.demodulise(type)} mints the same bare name now"
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def entity(name, &block)
          # A piece is declared IN this aggregate — its owner is stamped by
          # `Aggregate#initialize`, once the aggregate exists. Its own
          # commands were given the piece as their owner when it was declared,
          # so the chain closes as chapter -> aggregate -> entity -> command.
          # `owner_value_objects:` lets a PIECE's own `identified_by :field`
          # (see AttributeCollector#resolve_identity_field!) derive from a
          # value object this AGGREGATE declared — a piece has none of its
          # own — so the same bare-field form works at both levels.
          @entities << EntityBuilder.build(name, owner_value_objects: @value_objects + closed_sets, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, owner_attributes: attributes, &block)
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
          # with — stamped by `Aggregate#initialize` once the aggregate
          # exists. An ENTITY's commands take the entity as their owner instead,
          # at the entity's own declaration.
          @commands << CommandBuilder.build(name, owner: @name, &block)
        end

        def build
          resolve_pending_identity!
          seal_mutation_targets
          seal_query_targets
          seal_defaults

          ir = Aggregate.new(
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
            reference_targets: @reference_targets,
            provenance:    @provenance
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

        def resolve_pending_identity!
          if @identity_type_pending
            type, as, insert_at = @identity_type_pending
            @identity_paths = resolve_identity_type!(type, as, insert_at, @value_objects + closed_sets, @name)
          elsif @identity_field_pending
            @identity_paths = resolve_identity_field!(@identity_field_pending, @value_objects + closed_sets, @name)
          elsif @identity_fields_pending
            @identity_paths = @identity_fields_pending.flat_map do |field|
              resolve_identity_field!(field, @value_objects + closed_sets, @name)
            end
          end
        end

        # LEGACY — the two removed spellings (a value object + as:, and the
        # multi-line block), kept alive ONLY for `EraGuard.shadow_parse`
        # (S0a, ADR 0025) to still make sense of frozen era text that used
        # them; unreachable outside `MetaValidator.shadow_parsing?`.
        # Byte-identical to what `identified_by` did before this slice.
        def legacy_identified_by(target, as:, &path)
          if target
            raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

            if target.to_s[0] =~ /[A-Z]/
              @identity_type_pending = [target, as, attributes.size]
            else
              raise Malformed, "#{@name}.identified_by :#{target} takes no as: — as: only applies to identified_by ValueObject" if as

              @identity_field_pending = target
            end
            return
          end

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end

        # LEGACY — see `has_many`/`has_one`/`belongs_to`'s own comment;
        # byte-identical to what those three did before this slice.
        def legacy_has_many(type, as:, optional: false)
          plural = Naming.demodulise(type)
          reference_to(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym, optional: optional)
        end

        def legacy_has_one(type, as:, optional: false)
          reference_to(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym, optional: optional)
        end

        # Every reference is told which Aggregate declares it, so it can
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
              seal_query_field(owner, query, fields, lifecycle, query.order_by.field, ordering: true) if query.order_by
              seal_query_argument(owner, query, query.limit&.value)
              seal_query_argument(owner, query, query.offset&.value)
            end
          end
        end

        def query_surfaces
          [[@name, attributes, @lifecycle, @queries]] +
            @entities.map { |entity| ["#{@name}::#{entity.hecks_name}", entity.attributes, entity.lifecycle, entity.queries] }
        end

        # `/` CROSSES INTO ANOTHER RECORD, `.` WALKS FIELDS INSIDE THIS
        # ONE (ADR 0025, "References") — the operator answers which
        # kind of path this is now, not a name collision to arbitrate,
        # so a hop is routed to its own method before any `.`-splitting
        # runs at all; `seal_query_hop` below never sees a field this
        # one would also have tried to resolve as a local dotted walk.
        def seal_query_field(owner, query, fields, lifecycle, field, ordering: false)
          return seal_query_hop(owner, query, fields, field, ordering: ordering) if field.to_s.include?("/")

          name, *nested = field.to_s.split(".")
          attribute = fields.find { |candidate| candidate.name.to_s == name }
          if nested.empty? && attribute
            refuse_ambiguous_comparison!(owner, query, field, attribute)
            return
          end
          return if nested.empty? && lifecycle&.field.to_s == name
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

        # ORDER BY refuses a hop OUTRIGHT, right here — unlike a WHERE
        # hop (deferred below), this doesn't need the target's shape to
        # answer: an ask is ordered by what its own answering rows
        # hold, and a hop answers with a candidate set, not a sort key
        # (see Runtime::ReferenceHop).
        #
        # A WHERE hop is only RECOGNISED here, and CHECKED LATER. The
        # head names one of this aggregate's own references, which is
        # answerable now — a Reference knows its own target_name at
        # declaration. What it points AT is not: stamp_references has
        # already run by this point, but the chapter (Bluebook, and the
        # owning aggregate's OWN place in it) does not exist yet, so
        # Reference#resolve would answer nil for every target in the
        # file, including ones declared above this one. The tail, and
        # whether the target even exists, are BluebookBuilder's
        # business — see validate_query_hops!, which runs once the
        # chapter is real, for exactly the reason
        # validate_no_bidirectional_references! already gives for
        # living at that same later point.
        def seal_query_hop(owner, query, fields, field, ordering:)
          unless QuerySpecification::HopPath.hop_head?(field, fields)
            raise Malformed,
                  "#{owner}.#{query.hecks_name} asks about #{field}, which #{owner} " \
                  "never declares — a query over a field that does not exist " \
                  "matches nothing and refuses nothing"
          end

          return unless ordering

          raise Malformed,
                "#{owner}.#{query.hecks_name} orders by #{field}, which hops through " \
                "a reference — an ask is ordered by what its own answering rows " \
                "hold, and a hop answers with a candidate set, not a sort key"
        end

        def seal_ordered_comparator(owner, query, fields, clause)
          return unless ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)

          # A WHERE clause hopping through a reference with an ordered
          # comparator is legitimate ("client whose balance > 500") —
          # unlike ORDER BY (refused outright in seal_query_field, see
          # its own comment), a where-clause hop answers a real
          # candidate set either way, ordered or not. Deferred for the
          # same reason any other hop is: whether the tail is even
          # numeric is BluebookBuilder#validate_query_hops!'s question
          # to ask of the TARGET's shape, not this aggregate's own.
          return if clause.field.to_s.include?("/") && QuerySpecification::HopPath.hop_head?(clause.field, fields)

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

        # A BARE FIELD NAMING A VALUE OBJECT HAS TO SAY WHICH MEMBER IT
        # MEANS, when more than one could answer. The dotted case above
        # already refuses a path that lands on a value object rather than
        # a scalar; a bare name was returning unconditionally, so
        # `where(frequency: ...)` against a StatementFrequency
        # (cadence, retention_months, paper_fee_cents) compiled — and the
        # engines then disagreed about which member it meant, one taking
        # the FIRST numeric and another declining to unwrap at all.
        #
        # Unambiguous is: exactly one member, whatever its type, or
        # exactly one NUMERIC member among several (Money's `cents`
        # beside its `currency` — the reading every engine already
        # shared, and what the corpus relies on). Anything else names
        # its member with a dotted path, which already works.
        #
        # A list is exempt: `contains` over a `list_of` reads element
        # membership, not a scalar comparison, and has its own agreed
        # reading across the engines.
        def refuse_ambiguous_comparison!(owner, query, field, attribute)
          return if attribute.list?

          value_object = declared_value_object(attribute.type.to_s)
          return unless value_object

          members = QuerySpecification::Common::Comparison.ambiguous_members(value_object)
          return if members.empty?

          raise Malformed,
                "#{owner}.#{query.hecks_name} asks about #{field}, which names #{attribute.type} — " \
                "it has #{members.size} members (#{members.join(', ')}) and no single one a " \
                "comparison can mean; name the member (#{field}.#{members.first})"
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
