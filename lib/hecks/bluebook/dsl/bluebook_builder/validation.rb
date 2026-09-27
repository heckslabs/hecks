module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        # Whole-chapter, cross-aggregate checks that `#build` runs once a chapter is assembled.
        # Extended onto BluebookBuilder: pure functions of their arguments, no builder state.
        module Validation
          # Runs every whole-chapter check against one assembled chapter.
          # Public so `MetaValidator.judge_deferred!` can call it with no builder instance.
          #
          # @param bluebook [Bluebook::Chapter] the assembled chapter to validate
          # @return [void]
          # @raise [Bluebook::DSL::Malformed] if any check finds a violation
          # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if a
          #   `correlates_by` resolves to something other than a scalar field
          def validate_assembled!(bluebook)
            # an attribute type references its Shape, so an undeclared value object
            # fails resolution
            validate_reference_value_objects!(bluebook.aggregates)
            validate_correlation_keys!(bluebook.process_managers, bluebook.aggregates)
            validate_no_bidirectional_references!(bluebook.aggregates)
            unless MetaValidator.shadow_parsing?
              validate_event_shapes!(bluebook.aggregates)
              validate_with_projections!(bluebook.policies, bluebook.process_managers, bluebook.aggregates)
            end

            # Hops resolve only now: `Bluebook.new` has just stamped `hecks_owner` on
            # every aggregate.
            infer_hop_query_arguments!(bluebook)
            validate_query_hops!(bluebook)

            # A `projects` reference needs the same owner-stamped aggregates to resolve (ADR 0025).
            validate_projected_fields!(bluebook)

            validate_provisions!(bluebook)
          end

          # Checks every `provides` row against `Capabilities::CONTRACTS`.
          def validate_provisions!(bluebook)
            bluebook.provides.group_by(&:capability).each do |capability, rows|
              contract = Capabilities::CONTRACTS.fetch(capability) do
                raise Malformed, "#{bluebook.name} provides #{capability.inspect}, which is no capability the " \
                                 "language knows — known: #{Capabilities::CONTRACTS.keys.sort.join(', ')}"
              end

              keys = rows.map { |row| row.key.to_sym }
              unless keys.sort == contract.keys.sort
                raise Malformed, "#{bluebook.name} provides #{capability.inspect} with #{keys.join(', ')}, but " \
                                 "#{capability} needs exactly #{contract.keys.join(', ')}"
              end

              rows.each { |row| validate_provided_verb!(bluebook, capability, row, contract.fetch(row.key.to_sym)) }
            end
          end

          def validate_provided_verb!(bluebook, capability, row, kind)
            return validate_provided_port_operation!(bluebook, capability, row) if kind == :port_operation

            aggregate_name, member = row.verb.split(".", 2)
            aggregate = bluebook.aggregate(aggregate_name)
            return if aggregate && member && provided_member_names(aggregate, kind).include?(member)

            raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                             "which names no #{kind} this chapter declares (spelled \"Aggregate.#{kind.capitalize}\")"
          end

          # Only the verb's shape and aggregate are checkable here: the port is declared
          # in the hecksagon, which attaches after the chapter is built. `Registry#verify!`
          # checks the operation.
          def validate_provided_port_operation!(bluebook, capability, row)
            aggregate_name, port, operation = row.verb.split(".", 3)
            return if bluebook.aggregate(aggregate_name) && port && operation && !operation.include?(".")

            raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                             "which is not spelled \"Aggregate.Port.Operation\" over an aggregate this chapter declares"
          end

          def provided_member_names(aggregate, kind)
            kind == :command ? aggregate.commands.map(&:hecks_name) : aggregate.queries.map(&:name)
          end

          # Refuses an entity command that names its own entity as its root.
          # `CommandBuilder#reference_to` sets `references` only to the owner's bare name, so on
          # an aggregate command a head lookup is a tautology; only an entity self-reference fails.
          def validate_reference_value_objects!(aggregates)
            heads = aggregates.map(&:hecks_name)

            violations = aggregates.flat_map do |aggregate|
              aggregate.entities.flat_map do |entity|
                entity.commands.filter_map do |command|
                  next unless command.references
                  next if heads.include?(command.references.to_s)

                  "#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name} names itself as its root"
                end
              end
            end

            return if violations.empty?

            raise Malformed,
                  "an entity command is addressed through its aggregate; #{violations.uniq.join('; ')}"
          end

          # Every command that emits a given event must agree on its structural shape
          # (name, type, list, optional); `pattern:`/`admits:`/`default:` may differ (ADR 0025).
          def validate_event_shapes!(aggregates)
            event_emitters(aggregates).each do |event_name, pairs|
              next if pairs.size == 1

              shapes = pairs.map { |(owner, command)| event_shape(command, owner_aggregate(owner, aggregates)) }.uniq
              next if shapes.size == 1

              named = pairs.map { |(owner, command)| "#{owner}.#{command.hecks_name}" }.sort
              raise Malformed,
                    "#{event_name.inspect} is emitted with different shapes by #{named.join(' and ')} — " \
                    "an event is one fact, and every command that emits it must declare the same fields"
            end
          end

          # Checks `with:` projections against the source event's shape and the target's fields.
          # Same-chapter only: an unresolvable cross-chapter source or target is skipped.
          # A for_each policy's source is a query row with no known shape, so only its target
          # is checked.
          def validate_with_projections!(policies, process_managers, aggregates)
            lookup = command_lookup(aggregates)
            heads  = correlation_heads(process_managers)

            policies.each do |policy|
              next if policy.with_spec.to_a.empty?

              source_event = policy.for_each.to_s.empty? ? policy.on_event : nil
              check_with_spec!(policy.trigger_command, source_event, policy.with_spec, lookup,
                               "#{policy.name}'s trigger", aggregates, heads)
            end

            process_managers.each do |pm|
              pm.handlers.each do |handler|
                handler.dispatches.each do |dispatch|
                  next if dispatch.with_spec.to_a.empty?

                  check_with_spec!(dispatch.command_name, handler.event_type, dispatch.with_spec, lookup,
                                   "#{pm.name}'s dispatch #{dispatch.command_name}", aggregates, heads, process_manager: pm)
                end
              end
            end
          end

          # Checks one `with:` spec: each key must be a field the target command accepts,
          # and each Symbol source must be the correlation key, the emitter's identity, or a
          # field of the event's shape. A saga leg also falls back to the opening event's shape,
          # since saga memory starts as that payload. One closed sequence of per-field checks;
          # splitting it threads many locals.
          # rubocop:disable-next Metrics/CyclomaticComplexity
          # rubocop:disable-next Metrics/PerceivedComplexity
          def check_with_spec!(command_ref, event_name, with_spec, lookup, label, aggregates, correlation_heads,
                               process_manager: nil)
            target        = lookup[command_ref]
            source_shape  = event_name && event_shape_for(event_name, aggregates)
            memory_shape  = process_manager && event_shape_for(process_manager.starts_on, aggregates)
            correlation   = process_manager&.correlates_by && process_manager.correlation_head
            # A policy's source also carries the emitter's identity
            # (`PolicyInterpreter#emitter_identity`); a saga leg's source
            # (`SagaInterpreter#dispatch_args`) merges no such thing.
            identity_sources = process_manager.nil? && event_name ? event_identity_heads_for(event_name, aggregates) : []

            with_spec.each do |field, source|
              if target && !command_declares?(
                target, field, aggregates, correlation_heads
              )
                raise Malformed,
                      "#{label}'s with: names #{field.inspect}, which #{command_ref} does not declare"
              end

              next unless source.is_a?(::Symbol)
              next if source == correlation
              next if identity_sources.include?(source)
              next unless source_shape || memory_shape

              found = [source_shape, memory_shape].compact.any? { |shape| shape.any? { |name, *| name == source } }
              next if found

              raise Malformed, "#{label}'s with: reads :#{source} off #{event_name.inspect}, which does not declare it"
            end
          end

          # Mirrors `ArgumentGate#refuse_unknown_arguments`: `:id`, the owning aggregate's
          # `identity_heads` and `Naming.reference_key(command.references)` are all legal keys
          # beside the command's own attributes.
          def command_declares?(command, field, aggregates, correlation_heads)
            return true if command.attributes.any? { |a| a.name == field }
            return true if field == :id
            return true if correlation_heads.include?(field)
            return false unless command.references

            referenced = aggregates.find { |a| a.hecks_name == command.references }
            return false unless referenced

            referenced.identity_heads.include?(field) || Naming.reference_key(command.references) == field
          end

          # A saga's `correlates_by` head is a legal `with:` key: correlation rides
          # through commands that never read it.
          def correlation_heads(process_managers)
            process_managers.filter_map { |pm| pm.correlates_by && pm.correlation_head }
          end

          # Yields every command the chapter declares with its owner's name
          # ("Aggregate.Entity" for entities).
          def each_command(aggregates)
            return enum_for(:each_command, aggregates) unless block_given?

            aggregates.each do |aggregate|
              aggregate.commands.each { |command| yield aggregate.hecks_name, command }
              aggregate.entities.each do |entity|
                entity.commands.each { |command| yield "#{aggregate.hecks_name}.#{entity.hecks_name}", command }
              end
            end
          end

          # Not memoised: a chapter split across files is validated once per file, and a
          # cached index would miss the commands later files add.
          def event_emitters(aggregates)
            each_command(aggregates).with_object(Hash.new { |h, k| h[k] = [] }) do |(owner, command), index|
              command.emits.each { |event_name| index[event_name] << [owner, command] }
            end
          end

          # The comparable shape of a command's attributes, value objects unwrapped.
          # Structural, not nominal: aggregates may type a field with differently named
          # wrapper value objects without disagreeing about the event. `owner` supplies the
          # `value_object` lookup, since same-named value objects are private to each aggregate.
          def event_shape(command, owner)
            command.attributes.map { |a| [a.name, unwrap_shape(owner, a.type.to_s), a.list?, a.optional?] }.sort
          end

          def unwrap_shape(owner, type_name, seen = [])
            return type_name if owner.nil?
            return type_name if Attribute::PRIMITIVES.include?(type_name)
            # a self-referential value object bottoms out on its own name
            return type_name if seen.include?(type_name)

            shape = owner.value_object(type_name)
            return type_name unless shape

            shape.attributes.map { |a| [a.name, unwrap_shape(owner, a.type.to_s, seen + [type_name]), a.list?, a.optional?] }.sort
          end

          # The value objects a command's fields can be
          # typed with are the aggregate's own (`Entity` carries no
          # `value_object` lookup), so only the owner string's first segment matters.
          def owner_aggregate(owner, aggregates)
            aggregates.find { |a| a.hecks_name == owner.to_s.split(".").first }
          end

          def event_shape_for(event_name, aggregates)
            pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
            return nil if pairs.empty?

            owner_name, command = pairs.first
            event_shape(command, owner_aggregate(owner_name, aggregates))
          end

          # An entity's event is stamped with its owning aggregate's identity, so
          # "Game.Knight" answers Game's heads.
          def event_identity_heads_for(event_name, aggregates)
            pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
            return [] if pairs.empty?

            owner_name, = pairs.first
            aggregate = owner_aggregate(owner_name, aggregates)
            return [] unless aggregate

            heads = aggregate.identity_heads.map(&:to_sym)
            # An entity's event also carries the piece's own identity: the args a piece
            # was addressed by are its payload (`Emission#emit`).
            entity_names = owner_name.to_s.split(".").drop(1)
            entity = entity_names.reduce(aggregate) { |owner, name| owner&.entities&.find { |e| e.hecks_name == name } }
            heads + (entity ? entity.identity_heads.map(&:to_sym) : [])
          end

          def command_lookup(aggregates)
            each_command(aggregates).with_object({}) do |(owner, command), index|
              index["#{owner}.#{command.hecks_name}"] = command
            end
          end

          # A reference ring means no aggregate in it is a consistency boundary. Checked at
          # chapter level because seeing a cycle needs every end declared (ADR 0025). Catches
          # any ring length; self-reference stays legal, and a cross-chapter target is a
          # dangling name, not an edge.
          def validate_no_bidirectional_references!(aggregates)
            edges = aggregates.to_h do |aggregate|
              [aggregate.hecks_name, aggregate.reference_targets.uniq.reject { |target| target == aggregate.hecks_name }]
            end

            cycle = find_reference_cycle(edges)
            return unless cycle

            ring = "#{cycle.join(' -> ')} -> #{cycle.first}"
            raise Malformed,
                  "reference cycle: #{ring} — an aggregate points at another by id, and a " \
                  "ring back to where it started means no aggregate in it is a boundary " \
                  "anyone can reason about alone ; break the ring, or let one side be found " \
                  "through a query instead of a reference pointing back"
          end

          # Plain DFS with a visiting/done coloring; returns the ring in the order it
          # closes, or nil.
          def find_reference_cycle(edges)
            state = {}

            edges.each_key do |start|
              cycle = reference_cycle_from(start, edges, state, [])
              return cycle if cycle
            end

            nil
          end

          def reference_cycle_from(node, edges, state, path)
            return nil if state[node] == :done
            return path[path.index(node)..] if state[node] == :visiting

            state[node] = :visiting
            path.push(node)

            edges[node].each do |target|
              # a name this chapter never declares is dangling, not an edge
              next unless edges.key?(target)

              found = reference_cycle_from(target, edges, state, path)
              return found if found
            end

            path.pop
            state[node] = :done
            nil
          end

          # Resolves and checks every `where` hop deferred at aggregate-seal time.
          # An entity query that hops through a reference is refused outright: nothing follows
          # the hop at runtime (`QueryInterpreter#entity_rows` reads fields by literal key),
          # so it would match nothing.
          def validate_query_hops!(bluebook)
            bluebook.aggregates.each do |aggregate|
              aggregate.queries.each do |query|
                query.wheres.each do |clause|
                  next unless QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)

                  validate_hop_clause!(aggregate, query, clause)
                end
              end

              aggregate.entities.each { |entity| refuse_entity_query_hops!(aggregate, entity) }
            end
          end

          # Mints an implicit query attribute for each symbolic hop comparison, typed from
          # the scalar it compares against.
          def infer_hop_query_arguments!(bluebook)
            bluebook.aggregates.each do |aggregate|
              aggregate.queries.each do |query|
                query.wheres.each do |clause|
                  name = clause.value
                  next unless name.is_a?(Symbol)
                  next if query.attribute(name)
                  next unless QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)

                  plan = QuerySpecification::HopPath.plan(clause.field, aggregate.attributes)
                  next if plan.refusal || plan.hops.empty?

                  leaf = inferred_hop_leaf(name, plan)
                  next unless leaf

                  query.attributes << leaf
                end
              end
            end
          end

          def inferred_hop_leaf(name, plan)
            target = plan.hops.last.target
            head, *nested = plan.tail.to_s.split(".")
            if nested.empty? && target.lifecycle&.field.to_s == head
              Attribute.new(name: name, type: String)
            else
              root = target.attributes.find { |candidate| candidate.name.to_s == head }
              found = root && QuerySpecification::FieldPath.leaf_attribute(root, nested) do |type|
                target.value_object(type)
              end
              found && Attribute.new(name: name, type: found.type, list: found.list?)
            end
          end

          def refuse_entity_query_hops!(aggregate, entity)
            entity.queries.each do |query|
              query.wheres.each do |clause|
                next unless QuerySpecification::HopPath.hop_head?(clause.field, entity.attributes)

                raise Malformed,
                      "#{aggregate.hecks_name}::#{entity.hecks_name}.#{query.hecks_name} asks about " \
                      "#{clause.field}, which hops through #{entity.hecks_name}'s own reference — " \
                      "an entity query does not follow a hop the way an aggregate's own does; ask " \
                      "through the aggregate's own query instead, or open the target directly"
              end
            end
          end

          def validate_hop_clause!(aggregate, query, clause)
            plan = QuerySpecification::HopPath.plan(clause.field, aggregate.attributes)

            case plan.refusal
            when :unresolvable
              # HopPath.plan pushes even an unresolved hop onto `hops`, so `target_name`
              # is always there.
              raise Malformed,
                    "#{aggregate.hecks_name}.#{query.hecks_name} asks about #{clause.field}, " \
                    "which hops to #{plan.hops.last.target_name}, which this chapter never " \
                    "declares — a hop into an aggregate this chapter cannot see resolves to " \
                    "nothing, and a where that resolves to nothing matches nothing and " \
                    "refuses nothing"
            when :too_deep
              raise Malformed,
                    "#{aggregate.hecks_name}.#{query.hecks_name} asks about #{clause.field}, " \
                    "whose hop chain reaches #{QuerySpecification::HopPath::MAX_HOPS} " \
                    "references deep without landing — a chain this long is refused as a " \
                    "likely mistake, not a structural limit"
            end

            target = plan.hops.last.target
            validate_hop_tail!(aggregate, query, clause, target, plan.tail)
          end

          # Same three-way answer as `seal_query_field` (scalar, value object, or
          # nothing), asked of the hop's target.
          def validate_hop_tail!(aggregate, query, clause, target, tail)
            name, *nested = tail.to_s.split(".")
            attribute = target.attributes.find { |candidate| candidate.name.to_s == name }
            return validate_hop_comparator!(aggregate, query, clause, target, attribute, nested) if
              nested.empty? && (attribute || target.lifecycle&.field.to_s == name)
            return validate_hop_comparator!(aggregate, query, clause, target, attribute, nested) if
              nested.any? && attribute &&
              QuerySpecification::FieldPath.scalar_leaf?(attribute, nested) { |type| target.value_object(type) }

            if nested.any? && attribute &&
               !QuerySpecification::FieldPath.leaf_attribute(attribute, nested) { |type| target.value_object(type) }.nil?
              raise Malformed,
                    "#{aggregate.hecks_name}.#{query.hecks_name} asks about #{clause.field}, " \
                    "which hops to #{target.hecks_name} and then asks about #{tail}, which " \
                    "lands on a value object, not a scalar — a dotted query path ends on a " \
                    "scalar member, or the engines answer it differently"
            end

            raise Malformed,
                  "#{aggregate.hecks_name}.#{query.hecks_name} asks about #{clause.field}, " \
                  "which hops to #{target.hecks_name} and then asks about #{tail}, which " \
                  "#{target.hecks_name} never declares — a query over a field that does " \
                  "not exist matches nothing and refuses nothing"
          end

          # An ordered comparator over a hopped field must land on a number; the check
          # `AggregateBuilder#seal_ordered_comparator` deferred.
          def validate_hop_comparator!(aggregate, query, clause, target, attribute, nested)
            return unless AggregateBuilder::ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)
            return if attribute &&
                      QuerySpecification::FieldPath.numeric?(attribute, nested) { |type| target.value_object(type) }

            held = attribute ? "holds no number" : "is the lifecycle field, which holds text"
            raise Malformed,
                  "#{aggregate.hecks_name}.#{query.hecks_name} compares #{clause.field} with " \
                  "#{clause.op} after hopping to #{target.hecks_name}, but the field it lands " \
                  "on #{held} — an ordered comparison needs a numeric field, and over " \
                  "anything else the adapters answer differently or not at all"
          end

          # Checks each `projects` reference resolves to an aggregate declaring
          # `remote_field` as a scalar. A single hop never reaches HopPath::MAX_HOPS, so
          # :too_deep is not special-cased.
          def validate_projected_fields!(bluebook)
            bluebook.aggregates.each do |aggregate|
              aggregate.projected_fields.each { |field| validate_projected_field!(aggregate, field) }
            end
          end

          # Checks that one `projects` field's reference resolves to a real scalar.
          # One closed sequence over a single hop plan; splitting it scatters `plan`/`target`/
          # `remote_attribute` across methods that each need most of them.
          # rubocop:disable-next Metrics/AbcSize
          def validate_projected_field!(aggregate, field)
            plan = QuerySpecification::HopPath.plan("#{field.reference}/#{field.remote_field}", aggregate.attributes)

            if plan.refusal == :unresolvable
              raise Malformed,
                    "#{aggregate.hecks_name}.projects :#{field.name} reads through :#{field.reference}, " \
                    "which hops to #{plan.hops.last.target_name}, which this chapter never declares — " \
                    "a projection through an aggregate this chapter cannot see resolves to nothing"
            end

            target = plan.hops.last.target
            remote_attribute = target.attributes.find { |candidate| candidate.name.to_s == plan.tail }

            # A lifecycle field is a plain string by construction, so a name match is enough (as in
            # `validate_hop_tail!`).
            return if remote_attribute.nil? && target.lifecycle&.field.to_s == plan.tail

            # A projection may chain through another projection; `projected_fields` is
            # separate from `attributes`, and a projected value is always a scalar by
            # construction, so a name match is enough.
            return if remote_attribute.nil? && target.projected_fields.any? { |f| f.name.to_s == plan.tail }

            unless remote_attribute
              raise Malformed,
                    "#{aggregate.hecks_name}.projects :#{field.name} reads #{target.hecks_name}'s own " \
                    "#{plan.tail.inspect}, which #{target.hecks_name} never declares"
            end

            return if projectable_scalar?(target, remote_attribute)

            raise Malformed,
                  "#{aggregate.hecks_name}.projects :#{field.name} reads #{target.hecks_name}'s own " \
                  "#{plan.tail.inspect}, which is not a scalar — a projected field copies a single " \
                  "value, never a reference, a value object, or a list"
          end

          def projectable_scalar?(target, attribute)
            !attribute.list? && !attribute.reference? && target.value_object(attribute.type).nil?
          end

          # `correlates_by` must land on a scalar: the dotted path is walked against each
          # command that emits an event the process manager reacts to. A command lacking the
          # first segment is skipped, since correlation has fallback tiers
          # (saga_interpreter/correlation.rb).
          def validate_correlation_keys!(process_managers, aggregates)
            process_managers.each do |pm|
              next unless pm.correlates_by

              reason = correlation_key_violation(pm, aggregates)
              next unless reason

              raise ProcessManagerBuilder::InvalidProcessManager,
                    "#{pm.name} correlates_by #{pm.correlates_by.inspect}, but #{reason}"
            end
          end

          def correlation_key_violation(process_manager, aggregates)
            head, *rest = process_manager.correlates_by.to_s.split(".")
            events = reacted_events(process_manager)

            emitting_commands(events, aggregates).each do |owner, command|
              attribute = command.attributes.find { |a| a.name == head.to_sym }
              next unless attribute

              reason = list_or_scalar_violation(owner, attribute, rest)
              return reason if reason
            end

            nil
          end

          def reacted_events(process_manager)
            ([process_manager.starts_on, process_manager.ends_on] + process_manager.handlers.map(&:event_type))
              .compact
              .reject { |event| event == ProcessManager::REFUSED }
              .map { |event| event.to_s.split("::").last }
              .uniq
          end

          def emitting_commands(events, aggregates)
            aggregates.flat_map do |aggregate|
              commands = aggregate.commands + aggregate.entities.flat_map(&:commands)
              commands.select { |command| command.emits.map(&:to_s).intersect?(events) }
                      .map { |command| [aggregate, command] }
            end
          end

          def list_or_scalar_violation(owner, attribute, segments)
            if attribute.list?
              return "#{attribute.name} is a list — a correlation key must name one instance's own field, " \
                     "not a whole collection"
            end

            walk_scalar(owner, attribute.type.to_s, segments)
          end

          # Walks the remaining dotted segments through nested value objects; nil means the walk
          # bottomed out on a scalar, otherwise the string says why it cannot.
          def walk_scalar(owner, type_name, segments)
            if segments.empty?
              return nil if Attribute::PRIMITIVES.include?(type_name)

              return "#{type_name} is a value object, not a scalar — name one of its own fields, " \
                     "e.g. #{type_name.downcase}.value"
            end

            if Attribute::PRIMITIVES.include?(type_name)
              return "#{type_name} is already a scalar — #{segments.join('.')} has nothing left to reach"
            end

            shape = owner.value_object(type_name)
            return "#{type_name} is not a value object this domain declares" unless shape

            segment, *rest = segments
            attribute = shape.attributes.find { |a| a.name == segment.to_sym }
            return "#{type_name} has no field #{segment.inspect}" unless attribute
            if attribute.list?
              return "#{type_name}.#{segment} is a list — a correlation key must name one instance's own field, " \
                     "not a whole collection"
            end

            walk_scalar(owner, attribute.type.to_s, rest)
          end
        end
      end
    end
  end
end
