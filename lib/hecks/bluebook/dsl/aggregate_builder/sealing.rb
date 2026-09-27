module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # Build-time checks that what a command, query, or default names exists on the aggregate.
        # Included into AggregateBuilder; `#build` runs them once every declaration is in place.
        module Sealing
          private

          # Tells every reference which aggregate declares it, so it can resolve its target.
          #
          # Stamped at build because a command builder does not hold the aggregate. Walks every
          # list that can carry a reference: a missed one resolves to nil and is silently skipped.
          def stamp_references(aggregate)
            reference_bearing_attributes.each { |attribute| attribute.type.declared_in = aggregate }
          end

          # An owned piece's `reference_to` is an edge the aggregate points across too, so a ring
          # through a contained piece is refused like a direct aggregate-to-aggregate ring.
          # Command/query reference arguments are excluded: they are dispatch data, not state.
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

          # A default fills the shape it is declared on, or it fills nothing.
          #
          # A bare default on a value-object attribute builds cleanly and then refuses every
          # create at dispatch. A Hash default is left to `Value.for_attribute`.
          def seal_defaults
            # closed_sets too: an inline `one_of(...)` lives there until `#build` merges it.
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

          # A command's `from:` guard needs a lifecycle field to check against.
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

          # The local half of `projects` resolution: `reference` must name a reference attribute
          # here and `name` must not collide with a declared attribute. The target aggregate's
          # field is checked later by BluebookBuilder, once the whole chapter exists.
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

          # A mutation must name a field the aggregate actually has.
          #
          # Lives here, not in the language: a command's changes and the aggregate's fields hang
          # off different roots, and a given is a closed predicate over its own state.
          def seal_mutation_targets
            known = attributes.map { |attribute| attribute.name.to_sym }
            known << @lifecycle.field.to_sym if @lifecycle

            @commands.each do |command|
              command.mutations.each do |mutation|
                # :delegate targets an "Entity.Command" pair and :corrects an event name, not a
                # field; the latter is checked by `seal_correction_targets`.
                next if [:delegate, :corrects].include?(mutation.op)

                # The lifecycle field moves only by transition (C5.3). Frozen era text is exempt
                # (`MetaValidator.shadow_parsing?`) so it keeps parsing.
                if @lifecycle && mutation.target.to_sym == @lifecycle.field.to_sym && !MetaValidator.shadow_parsing?
                  raise Malformed,
                        "#{@name}.#{command.hecks_name} sets #{mutation.target}, #{@name}'s lifecycle field — " \
                        "a lifecycle field moves only by transition; declare one instead of setting it"
                end
                next if known.include?(mutation.target.to_sym)

                raise Malformed,
                      "#{@name}.#{command.hecks_name} sets #{mutation.target}, which #{@name} " \
                      "never declares — a mutation into a field that does not exist " \
                      "writes nothing and refuses nothing"
              end
            end
          end

          # Checks `corrects` once every sibling command is known: the named event must be emitted
          # by a command on this aggregate, and `reverses: true` needs every source mutation to be
          # an increment/decrement, the only ops invertible without runtime data.
          #
          # One cluster of sequential rules against one command, each `raise` gating the next.
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

          # A query must ask about a field the aggregate has. A dotted path must land on a scalar
          # member, an ordered comparator (lt/gt/gte/lte) on a numeric leaf, and a :symbol value
          # must name one of the query's own arguments; else engines disagree or match nothing.
          #
          # `private` does not apply to constants; this sits beside the method that reads it.
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

          # `/` crosses into another record and `.` walks fields inside this one, so a hop is
          # routed to `seal_query_hop` before any `.`-splitting.
          #
          # A closed decision tree over where a field can resolve: hop, local scalar, lifecycle
          # field, value object (refused), or nothing (refused).
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

          # ORDER BY refuses a hop outright: a hop answers with a candidate set, not a sort key.
          #
          # A where hop is only recognised here. Its head must be one of this aggregate's own
          # references, but the target cannot resolve before the chapter exists, so
          # BluebookBuilder#validate_query_hops! checks the tail and the target later.
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

            # A where hop with an ordered comparator is legitimate; whether its tail is numeric
            # is BluebookBuilder#validate_query_hops!'s question, so it is deferred.
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

          # A symbolic right-hand side is a query input; when the compared path lands on this
          # owner's shape its type is known, so no `attribute` line is needed. Reference hops
          # are inferred later by BluebookBuilder, once the chapter is owner-stamped.
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

          # A bare field naming a value object must say which member it means when several could
          # answer; otherwise engines disagree (first numeric member vs. no unwrap at all).
          #
          # Unambiguous is exactly one member, or exactly one numeric member among several.
          # A list is exempt: `contains` reads element membership, not a scalar comparison.
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
