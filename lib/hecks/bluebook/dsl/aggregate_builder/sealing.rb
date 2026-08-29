module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # THE "SEAL_*" PASS — everything `#build` runs once every
        # declaration (attributes, entities, commands, queries, the
        # lifecycle) is otherwise in place, checking that what a command,
        # query, or default NAMES actually exists elsewhere on the
        # aggregate. Split out of aggregate_builder.rb (which keeps the
        # DSL surface itself — attribute/command/query/policy declaration
        # — and the smaller drain_pending!/identity bookkeeping) because
        # this cluster is one cohesive concern: cross-field validation
        # that can only run after every declaration is real, the same
        # relationship BluebookBuilder's own `self.validate_*` cluster has
        # to ITS chapter (see that file's own header for the parallel).
        # `include`d back into AggregateBuilder, same pattern as
        # `Runtime::Registry`'s own `include Verification` /
        # `include SagaPersistence` — same class, its private instance
        # methods, just filed by responsibility across files.
        module Sealing
          private

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
          def stamp_references(aggregate)
            reference_bearing_attributes.each { |attribute| attribute.type.declared_in = aggregate }
          end

          # AN OWNED PIECE'S OWN `reference_to` IS AN EDGE THIS AGGREGATE
          # POINTS ACROSS TOO (S9, ADR 0025 — "entity/aggregate shared
          # vocabulary") — a ring closing through a contained piece (Board
          # -> Board::Card -> Product -> Board) is the same "no boundary
          # anyone can reason about alone" `validate_no_bidirectional_
          # references!` already refuses for a direct aggregate-to-
          # aggregate ring; it was invisible before this because only
          # `AggregateBuilder#reference_to` ever fed `@reference_targets`,
          # never `EntityBuilder#reference_to`. Command/query reference
          # ARGUMENTS are deliberately excluded — they are data flowing
          # through a dispatch, not persisted state the graph a cycle
          # means anything over.
          def entity_reference_targets
            @entities.flat_map { |entity| entity.attributes.select(&:reference?).map { |a| a.type.target_name.to_s } }
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
            # `closed_sets` TOO, not only `@value_objects` — the exact gap
            # this method's own comment names: an inline `one_of(...)`
            # synthesises its value object through `closed_sets`
            # (AttributeCollector#synthesise_closed_set), never installed
            # into `@value_objects` until `#build` merges them (see
            # `#build`'s own `@value_objects + closed_sets`, and
            # `declared_value_object`'s identical merge). Checking
            # `@value_objects` alone made this exact attribute — a bare
            # default on an inline closed set — invisible to the one
            # check meant to catch it.
            shapes = (@value_objects + closed_sets).map { |shape| shape.hecks_name.to_s }

            attributes.each do |attribute|
              next if attribute.default.nil? || attribute.default.is_a?(Hash)
              next unless shapes.include?(attribute.type.to_s)

              raise Malformed,
                    "#{@name}.#{attribute.name} defaults to #{attribute.default.inspect}, but " \
                    "#{attribute.type} is a value object — a default fills its FIELDS " \
                    "(default: { ... }), and a bare value refuses every create instead"
            end
          end

          # A command's `from:` guard needs a lifecycle field to check
          # against — declared at BUILD time (S10, ADR 0025), the same
          # point every other "does this actually resolve" check in this
          # file runs, rather than left to crash `enforce_lifecycle_
          # guard` the first time such a command is ever dispatched.
          def seal_lifecycle_guards
            return if @lifecycle

            @commands.each do |command|
              next unless command.from

              raise Malformed,
                    "#{@name}.#{command.hecks_name} guards from: #{Array(command.from).inspect}, but " \
                    "#{@name} declares no lifecycle — from: checks a lifecycle field, and there is " \
                    "none here to check"
            end
          end

          # `projects`'s OWN half of "does this actually resolve" (S12,
          # ADR 0025) — the LOCAL half only: `reference` must name a real
          # reference-typed attribute this aggregate declares, and
          # `name` must not collide with an attribute already declared
          # (a projected field is its own kind of field, never a second
          # spelling of one that already exists). The TARGET aggregate's
          # own field is checked separately, once every aggregate in the
          # chapter is real — see BluebookBuilder#validate_projected_
          # fields!'s own comment for why that half cannot happen here.
          def seal_projected_fields
            declared = attributes.map { |attribute| attribute.name.to_sym }

            @projected_fields.each do |field|
              if declared.include?(field.name)
                raise Malformed,
                      "#{@name}.projects :#{field.name} names a field #{@name} already declares — " \
                      "a projected field is never a second spelling of one that already exists"
              end

              reference_attribute = attributes.find { |attribute| attribute.name == field.reference }
              unless reference_attribute&.reference?
                raise Malformed,
                      "#{@name}.projects :#{field.name} reads through #{field.reference.inspect}, which " \
                      "#{@name} never declares as a reference_to — projects reads through a REFERENCE, " \
                      "never a value object or a scalar"
              end
            end
          end

          def seal_mutation_targets
            known = attributes.map { |attribute| attribute.name.to_sym }
            known << @lifecycle.field.to_sym if @lifecycle

            @commands.each do |command|
              command.mutations.each do |mutation|
                # `:delegate` — CommandBuilder#delegates_to's own comment —
                # targets no field of THIS aggregate at all; its `target`
                # names an "Entity.Command" pair instead, checked when the
                # command builds (`delegates_to`'s own `rpartition` guard)
                # and again at dispatch time (`CommandInterpreter
                # #step_delegate_to_entity`, which refuses a real one that
                # names no such entity or command). Sealing THIS check
                # against it would refuse every delegating command outright.
                # `:corrects` — CommandBuilder#corrects_impl's own comment —
                # targets an EVENT name, not a field either; checked instead
                # by `seal_correction_targets`, below.
                next if [:delegate, :corrects].include?(mutation.op)
                next if known.include?(mutation.target.to_sym)

                raise Malformed,
                      "#{@name}.#{command.hecks_name} sets #{mutation.target}, which #{@name} " \
                      "never declares — a mutation into a field that does not exist " \
                      "writes nothing and refuses nothing"
              end
            end
          end

          # `corrects` — CommandBuilder#corrects_impl's own comment. Runs
          # once every command in the aggregate is known (the same reason
          # this is a `seal_*` step rather than living in `corrects_impl`
          # itself — a command cannot see its own siblings' `emits` while
          # it is still being built). Two things are checked:
          #
          # 1. The named event must be something a SIBLING command here
          #    actually `emits` — naming an event nothing in this aggregate
          #    ever announces is a build-time authoring error. (Whether
          #    THIS record has actually emitted it YET is the dispatch-time
          #    half — CommandRules::Admissibility#enforce_correction_target.)
          #
          # 2. `reverses: true` derives the corrective `sets` from the
          #    ORIGINAL command's own mutations, rather than the author
          #    writing them — but only when every one of those mutations is
          #    STRUCTURALLY invertible with no runtime data: increment/
          #    decrement, same argument, opposite verb (`sign_for`'s own
          #    +1/-1 pair — CommandRules::Arithmetic applies `current +
          #    sign * amount`, so the SAME source with the OPPOSITE sign
          #    undoes it exactly). Nothing else qualifies today: `set` has
          #    no such rule at all — inverting it needs the SPECIFIC prior
          #    value at the moment the original fired, which is per-
          #    instance runtime data no build-time derivation can have;
          #    `multiply`/`clamp` are lossy by design (a clamped value's
          #    own pre-clamp magnitude is not recoverable from the mutation
          #    at all); `append`/`remove` LOOK symmetric but are not
          #    reliably so — `append`'s source is a per-field binding hash
          #    (`append: { name: :name, amount: :amount }`), `remove`'s is
          #    a single resolved value to match by equality
          #    (MutationApplier#removed), and collapsing one shape into the
          #    other correctly needs the target list's own value-object
          #    field names, not just the mutation's own recorded shape — a
          #    real gap, left for a follow-on round rather than guessed at
          #    here. Refuses rather than silently deriving something wrong
          #    — see docs/decisions/ for the ADR that draws this exact
          #    line.
          # One closed cluster of `corrects`/`reverses: true` rules, run
          # in sequence against ONE command at a time (emission exists,
          # reverses/own-sets conflict, invertibility, then the actual
          # derivation) — each `raise` gates the next check for THAT
          # command, and `inverse_op`/`emitted_by` are shared read-only
          # lookups built once up front. Splitting the per-command body
          # out would still need all of `command`/`event`/`sources`/
          # `inverse_op` passed in, for no clearer a result.
          # rubocop:disable-next Metrics/AbcSize
          # rubocop:disable-next Metrics/CyclomaticComplexity
          # rubocop:disable-next Metrics/PerceivedComplexity
          def seal_correction_targets
            inverse_op = { increment: :decrement, decrement: :increment }
            emitted_by = Hash.new { |hash, key| hash[key] = [] }
            @commands.each { |command| command.emits.each { |event_name| emitted_by[event_name] << command } }

            @commands.each do |command|
              correction = command.mutations.find { |mutation| mutation.op == :corrects }
              next unless correction

              event   = correction.target
              sources = emitted_by[event]
              if sources.empty?
                raise Malformed,
                      "#{@name}.#{command.hecks_name} corrects #{event.inspect}, but nothing " \
                      "declared on #{@name} ever emits it — corrects names a fact this " \
                      "aggregate actually announces, not an aspiration"
              end

              next unless correction.source[:reverses]

              own_mutations = command.mutations.reject { |mutation| mutation.op == :corrects }
              if own_mutations.any?
                raise Malformed,
                      "#{@name}.#{command.hecks_name} declares both corrects #{event.inspect}, " \
                      "reverses: true AND its own sets — reverses: true means the correction " \
                      "is DERIVED; write one or the other, never both"
              end

              derived     = sources.flat_map(&:mutations).reject { |mutation| mutation.op == :corrects }
              unsupported = derived.reject { |mutation| inverse_op.key?(mutation.op) }
              if unsupported.any?
                raise Malformed,
                      "#{@name}.#{command.hecks_name} corrects #{event.inspect}, reverses: " \
                      "true, but the command(s) that emit it use " \
                      "#{unsupported.map(&:op).uniq.join(', ')} — not statically invertible " \
                      "(set needs the specific prior value, multiply/clamp are lossy) — " \
                      "declare the corrective sets by hand instead"
              end

              derived.each do |mutation|
                command.mutations << Mutation.new(target: mutation.target, op: inverse_op.fetch(mutation.op),
                                                  source: mutation.source)
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
          # `private` above has no effect on a constant (Ruby constants are
          # always resolvable through their lexical scope); kept here anyway,
          # beside the method that actually reads it, for the narrative.
          # rubocop:disable-next Lint/UselessConstantScoping
          ORDERED_COMPARATORS = %i[lt lte gt gte].freeze

          def seal_query_targets
            query_surfaces.each do |owner, fields, lifecycle, queries|
              queries.each do |query|
                query.wheres.each do |clause|
                  seal_query_field(owner, query, fields, lifecycle, clause.field)
                  seal_ordered_comparator(owner, query, fields, clause)
                  infer_local_query_argument(query, fields, lifecycle, clause)
                  seal_query_argument(owner, query, clause.value) unless clause.field.to_s.include?("/")
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
          # A closed decision tree over where ONE field can resolve —
          # hop, local scalar, lifecycle field, value object (refused),
          # or nothing (refused) — see the doc comment above (and the
          # method-level comments on the hop/ordering split) for why each
          # branch exists. Every branch already reads as its own named
          # rule; extracting pieces would just relocate them.
          # rubocop:disable-next Metrics/CyclomaticComplexity
          # rubocop:disable-next Metrics/PerceivedComplexity
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

          # A symbolic right-hand side is a query input. When the compared path
          # lands on this owner's declared shape, its type is already known and
          # repeating an `attribute` line inside the query adds no information.
          # Reference hops are resolved only after the whole chapter has been
          # owner-stamped; BluebookBuilder performs the identical inference for
          # those deferred paths.
          def infer_local_query_argument(query, fields, lifecycle, clause)
            name = clause.value
            return unless name.is_a?(Symbol)
            return if query.attribute(name)
            return if clause.field.to_s.include?("/")

            head, *nested = clause.field.to_s.split(".")
            leaf = if nested.empty? && lifecycle&.field.to_s == head
                     Attribute.new(name: name, type: String)
                   else
                     root = fields.find { |candidate| candidate.name.to_s == head }
                     found = root && QuerySpecification::FieldPath.leaf_attribute(root, nested) do |type|
                       declared_value_object(type)
                     end
                     found && Attribute.new(name: name, type: found.type, list: found.list?)
                   end
            query.attributes << leaf if leaf
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
end
