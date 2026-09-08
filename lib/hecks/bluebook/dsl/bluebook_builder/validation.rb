module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        # THE self.validate_*/self.correlation_*/self.event_*/self.walk_*
        # CLUSTER — every whole-chapter, cross-aggregate check `#build`
        # runs once a chapter is fully assembled (reference targets, event
        # shapes, correlation keys, query hops, projected fields,
        # bidirectional-reference cycles), plus each one's own private
        # helpers. Split out of bluebook_builder.rb (which keeps the DSL
        # surface — chapter/aggregate/read_model/policy declaration,
        # `#build`, and `self.build`) for the same reason
        # AggregateBuilder::Sealing exists: one cohesive concern, filed by
        # responsibility rather than by an arbitrary line count.
        #
        # `extend`ed onto BluebookBuilder rather than `include`d — every
        # one of these is a pure function of its own explicit arguments
        # (an assembled `Bluebook::Chapter`, an aggregate list, ...), never
        # builder-instance state (no `@ivar` read anywhere in this
        # module — checked before splitting it out), and every caller
        # reaches these as `BluebookBuilder.validate_assembled!(...)`
        # class-level calls, `#build`'s own `self.class.validate_assembled!`
        # included. `extend` is `include`'s class-level counterpart: the
        # same "one class, its methods, filed across files" pattern
        # `Runtime::Registry` already uses (`include Verification`), just
        # turning each method into a class (singleton) method instead of
        # an instance method, matching what `def self.foo` already made
        # every one of these before the split.
        module Validation
          # EVERY WHOLE-CHAPTER CHECK, IN ONE PLACE — the battery `#build`
          # used to run inline, now a pure function of an assembled
          # `Bluebook::Chapter` so `MetaValidator.judge_deferred!` can run
          # it too, once, on a chapter whose files have ALL loaded (see
          # `#build`'s own comment for why that split exists at all).
          # Public, not `private_class_method`'d, for exactly that second
          # caller — `MetaValidator` needs to reach this with no builder
          # instance in hand, only the chapter `judge_deferred!` already
          # read back out of the registry.
          def validate_assembled!(bluebook)
            # moved to the language: an attribute type is a reference to its Shape,
            # so an undeclared value object fails reference resolution
            validate_reference_value_objects!(bluebook.aggregates)
            validate_correlation_keys!(bluebook.process_managers, bluebook.aggregates)
            validate_no_bidirectional_references!(bluebook.aggregates)
            unless MetaValidator.shadow_parsing?
              validate_event_shapes!(bluebook.aggregates)
              validate_with_projections!(bluebook.policies, bluebook.process_managers, bluebook.aggregates)
            end

            # Every hop AggregateBuilder#seal_query_field recognised and
            # deferred gets checked for real here — the earliest point a
            # hop CAN be checked, for exactly the reason
            # validate_no_bidirectional_references! above already gives:
            # `Bluebook.new` just stamped `hecks_owner` on every
            # aggregate, so `Reference#resolve` finally has a chapter to
            # walk. Before this line every target in the file (including
            # ones declared ABOVE the aggregate doing the asking) would
            # have resolved to nil.
            infer_hop_query_arguments!(bluebook)
            validate_query_hops!(bluebook)

            # Same precondition, same reason: a `projects` declaration's
            # own reference cannot resolve until every aggregate in the
            # chapter is real and owner-stamped (S12, ADR 0025).
            validate_projected_fields!(bluebook)
          end

          # AN ENTITY COMMAND MAY NOT NAME ITSELF AS ITS ROOT.
          #
          # That is the whole of what is left here, and it needs saying plainly
          # because the sentence this used to raise — "references must target
          # aggregate heads" — was never what it checked.
          #
          # `CommandBuilder#reference_to` sets `references` ONLY when the target's
          # bare name equals the owner's ; anything else becomes a reference
          # ATTRIBUTE. So on an aggregate command `references` is always a copy of
          # that aggregate's own name, and looking it up in an index of aggregates
          # is a TAUTOLOGY — that branch never refused anything and structurally
          # could not. Verified across all eight golden chapters before deleting it.
          #
          # On a PIECE's command the owner is the entity, and an entity is not a
          # head, so what this actually refuses is `reference_to <its own name>`
          # written inside `entity do … end`. A piece is reached THROUGH its
          # aggregate ; a command on one addresses the aggregate, never the piece.
          #
          # Reference ATTRIBUTES are the language's business now — offered as the
          # head's own id and resolved as references, so `Aggregate.Reference` and
          # `Command.Reference` refuse an undeclared head with no predicate at all.
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

          # EVENTS ARE FIRST-CLASS BY CONVENTION, NOT BY DECLARATION (ADR
          # 0025, "events and reactions" — "a domain event is a value
          # object with its own attributes, not a label"). No new `event
          # do ... end` construct exists to hand-author and keep in step
          # with every emitting command by hand — an event's own known
          # shape IS whichever command(s) declare `emits` for its name, and
          # this is the ONE thing that has to hold for that convention to
          # mean anything: every command that emits a given name has to
          # agree on what it carries. An event is one fact; a fact does not
          # carry two different truths depending on who is telling it.
          #
          # STRUCTURAL fields only (name/type/list/optional) — `pattern:`/
          # `admits:`/`default:` are refinements ON a field, not a second
          # claim about what the payload holds, so two emitting commands
          # are free to differ there without actually disagreeing about
          # the event's own shape.
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

          # THE "EXPENSIVE HALF" the ADR names: "with: { account: :account }
          # projecting into a reaction that has no declared contract ...
          # breaks at dispatch rather than at load." Checked here, now that
          # `validate_event_shapes!` (above) guarantees at most one real
          # shape per event name, and command references being first-class
          # (`Naming.command_ref`) means the TARGET side is a real
          # resolvable command, not a string that might be a typo.
          #
          # SAME-CHAPTER ONLY, ON PURPOSE — a `with:` whose source event or
          # target command lives outside this chapter (an `across` policy
          # reacting to another domain's event entirely) is silently left
          # unchecked rather than refused: there is nothing here yet to
          # check it against, and "unresolvable" is not the same claim as
          # "wrong."
          #
          # A FOR_EACH POLICY'S SOURCE ISN'T THE EVENT AT ALL — a fan-out
          # `with:`'s symbols read the QUERY ROW `for_each` answers
          # (FreezeAccountsOnSuspension's own comment: "`account` is the
          # key the fan-out merges for each row"), which this has no shape
          # for; the SOURCE half is skipped for those, the TARGET half
          # (does the dispatched command actually declare the field) still
          # runs, since that half is true regardless of where the value
          # came from.
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

          # `process_manager:` is present only for a process manager's own dispatch — a
          # saga leg's source symbol resolves against the CURRENT triggering
          # event first, same as a policy, but falls all the way back to the
          # saga's own MEMORY when the current event does not carry it
          # (`SagaInterpreter#dispatch_args`, its own last `else`) — and
          # memory starts as the OPENING event's payload
          # (`SagaInterpreter#instance = { ..., memory: event.payload }`,
          # never updated after), never the leg's own. Settlement's own
          # comment names exactly this: "the credit leg reads a destination
          # no event carried" — `AccountDebited` never declares `:reference`,
          # only `TransferRequested` (`pm.starts_on`) does, and that is
          # where the value is genuinely still coming from.
          # One closed sequence of per-field checks against a fixed set of
          # legal `with:` sources (target's own attributes, correlation,
          # emitter identity, event/memory shape) — see the comment above
          # for why each source is legal. Extracting the loop body would
          # mean threading ten-plus already-resolved locals (target,
          # source_shape, memory_shape, correlation, identity_sources, ...)
          # into a new method for no gain: each `next`/`raise` already
          # reads as its own rule at its own site.
          # rubocop:disable-next Metrics/CyclomaticComplexity
          # rubocop:disable-next Metrics/PerceivedComplexity
          def check_with_spec!(command_ref, event_name, with_spec, lookup, label, aggregates, correlation_heads,
                               process_manager: nil)
            target        = lookup[command_ref]
            source_shape  = event_name && event_shape_for(event_name, aggregates)
            memory_shape  = process_manager && event_shape_for(process_manager.starts_on, aggregates)
            correlation   = process_manager&.correlates_by && process_manager.correlation_head
            # A POLICY'S SOURCE ALSO CARRIES THE EMITTER'S OWN IDENTITY —
            # `PolicyInterpreter#emitter_identity`, the runtime half of this.
            # An entity command's event never declares its aggregate's
            # identity (it arrives through `reference_to`, not an
            # `attribute`), so before this a policy on `KnightCaptured` could
            # not spell `with: { label: :label }` at all — "reads :label off
            # KnightCaptured, which does not declare it" — and chess's
            # AdvancePly grew optional, unread attributes just to survive a
            # wholesale forward. Policies only: a saga leg's own source is
            # `SagaInterpreter#dispatch_args`, which merges no such thing.
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

          # A command's OWN `reference_to` (bare, no `as:`) never lands in
          # `attributes` — `CommandBuilder#reference_to`'s self-reference
          # branch sets `command.references` instead (S2), and mints no new
          # field at all. What addresses it is not one name but the SAME
          # SET `CommandInterpreter::ArgumentGate#refuse_unknown_arguments`
          # already accepts at dispatch time — `:id`, the owning aggregate's
          # own `identity_heads` (real corpus proof — `Account.Debit`
          # dispatched everywhere as `number: ...`, `Account`'s own
          # `identified_by`), AND `Naming.reference_key(command.references)`
          # (real corpus proof — `FreezeAccountsOnSuspension`'s `for_each`
          # fan-out, whose own comment reads "`account` is the key the
          # fan-out merges for each row it answers"). Both are simultaneously
          # legal there, not context-dependent alternatives, so both are
          # legal here : this mirrors that gate rather than re-deriving a
          # narrower rule that would refuse one of two real, already-shipped
          # dispatch conventions.
          def command_declares?(command, field, aggregates, correlation_heads)
            return true if command.attributes.any? { |a| a.name == field }
            return true if field == :id
            return true if correlation_heads.include?(field)
            return false unless command.references

            referenced = aggregates.find { |a| a.hecks_name == command.references }
            return false unless referenced

            referenced.identity_heads.include?(field) || Naming.reference_key(command.references) == field
          end

          # THE FOURTH addressing key `ArgumentGate#refuse_unknown_arguments`
          # accepts, alongside `:id`/`identity_heads`/`reference_key` — every
          # saga in THIS domain's own `correlates_by` head, carried through
          # every dispatch as pure passthrough (Settlement's own comment:
          # "`reference:` carries the correlation forward... this is pure
          # passthrough, not an addressing key"). A command declaring none of
          # its attributes named this is not a gap; the correlation key rides
          # through commands that never read it, same as it does at runtime.
          def correlation_heads(process_managers)
            process_managers.filter_map { |pm| pm.correlates_by && pm.correlation_head }
          end

          # Every command this chapter declares, an aggregate's own AND
          # every entity nested inside one, paired with a name for what
          # declares it — shared by `validate_event_shapes!` and
          # `validate_with_projections!`'s own command lookup, the same
          # reach `HecksagonBuilder#commands_in` needs one level up (S8).
          def each_command(aggregates)
            return enum_for(:each_command, aggregates) unless block_given?

            aggregates.each do |aggregate|
              aggregate.commands.each { |command| yield aggregate.hecks_name, command }
              aggregate.entities.each do |entity|
                entity.commands.each { |command| yield "#{aggregate.hecks_name}.#{entity.hecks_name}", command }
              end
            end
          end

          # NOT MEMOISED — this used to be `@event_emitters ||=` on the
          # builder instance, which is safe for a one-file chapter but
          # wrong for one split across several: the FIRST file's build()
          # call would compute and cache it from whatever `@aggregates`
          # held at that moment, and every later file's own validation
          # would keep reading that same stale snapshot, silently missing
          # any command a later file adds. Recomputed fresh every call
          # instead — this walks the whole chapter once per `#build`, not
          # a hot path worth memoising at that cost.
          def event_emitters(aggregates)
            each_command(aggregates).with_object(Hash.new { |h, k| h[k] = [] }) do |(owner, command), index|
              command.emits.each { |event_name| index[event_name] << [owner, command] }
            end
          end

          # STRUCTURAL, NOT NOMINAL. Two commands on two different
          # aggregates that both `emits "SameEvent"` are free to type a
          # field through two DIFFERENT, locally-scoped wrapper value
          # objects (e.g. one aggregate's own `value: SomeText` vs
          # another's `value: OtherText`, exactly the per-aggregate "own
          # text VO" convention every aggregate in this grammar already
          # follows for everything from `RuleText` to `FieldRef`) without
          # actually disagreeing about the event's shape — comparing
          # `a.type` by NAME would flag that as a violation for no real
          # reason: an event is one fact, and two isomorphic wrapper types
          # tell an identical one. So a value-object type is unwrapped to
          # its OWN attribute shape (recursively — a wrapper could itself
          # wrap another) before comparing, and only a primitive type
          # (nothing left to unwrap) or two VOs that truly differ once
          # unwrapped still counts as a real mismatch. `owner` carries the
          # type's `value_object` lookup — a command's own attributes only
          # know their type's NAME, never the aggregate that declared it,
          # and two sibling aggregates in one chapter each keep a
          # same-named VO private to themselves, so the unwrap has to ask
          # the SAME aggregate the field's own command belongs to, never a
          # neighbor's.
          def event_shape(command, owner)
            command.attributes.map { |a| [a.name, unwrap_shape(owner, a.type.to_s), a.list?, a.optional?] }.sort
          end

          def unwrap_shape(owner, type_name, seen = [])
            return type_name if owner.nil? # owner couldn't be resolved -- compare by name, same as before this unwrap existed
            return type_name if Attribute::PRIMITIVES.include?(type_name)
            # a self-referential VO bottoms out on its own name, not an infinite unwrap
            return type_name if seen.include?(type_name)

            shape = owner.value_object(type_name)
            return type_name unless shape # not this owner's own VO (a reference type, say) -- nothing further to unwrap

            shape.attributes.map { |a| [a.name, unwrap_shape(owner, a.type.to_s, seen + [type_name]), a.list?, a.optional?] }.sort
          end

          # `owner` (from `each_command`) is a plain STRING — the aggregate's
          # `hecks_name` alone, or `"Aggregate.Entity"` for an entity's own
          # command. Either way the VALUE OBJECTS a command's fields can be
          # typed with are the AGGREGATE's own (`Entity` carries no
          # `value_object` lookup of its own — the whole rest of this file
          # already resolves hop/type lookups only at the aggregate level,
          # e.g. `validate_hop_tail!`'s `target.value_object(type)`), so only
          # the first segment ever matters here.
          def owner_aggregate(owner, aggregates)
            aggregates.find { |a| a.hecks_name == owner.to_s.split(".").first }
          end

          def event_shape_for(event_name, aggregates)
            pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
            return nil if pairs.empty?

            owner_name, command = pairs.first
            event_shape(command, owner_aggregate(owner_name, aggregates))
          end

          # The identity heads of the aggregate that emits `event_name` — an
          # entity's event is stamped with its OWNING aggregate's identity
          # (`Event#id` is the parent's), so an owner spelled "Game.Knight"
          # answers Game's heads.
          def event_identity_heads_for(event_name, aggregates)
            pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
            return [] if pairs.empty?

            owner_name, = pairs.first
            aggregate = owner_aggregate(owner_name, aggregates)
            return [] unless aggregate

            heads = aggregate.identity_heads.map(&:to_sym)
            # AN ENTITY'S EVENT ALSO CARRIES THE PIECE'S OWN IDENTITY — the
            # args a piece was addressed by are the args its event announces
            # (`Emission#emit`: `payload: args`), so `id`-shaped heads are
            # genuinely there at runtime even though no `attribute` line on
            # the entity command declares them.
            entity_names = owner_name.to_s.split(".").drop(1)
            entity = entity_names.reduce(aggregate) { |owner, name| owner&.entities&.find { |e| e.hecks_name == name } }
            heads + (entity ? entity.identity_heads.map(&:to_sym) : [])
          end

          def command_lookup(aggregates)
            each_command(aggregates).with_object({}) do |(owner, command), index|
              index["#{owner}.#{command.hecks_name}"] = command
            end
          end

          # A REFERENCE RING IS NOT A MODELLING CHOICE, IT IS A MISSING ONE
          # — a DDD aggregate is a consistency boundary precisely because
          # something outside it can only ever point IN, by id, never the
          # other way. A caller must be able to reason about one aggregate
          # alone ; a ring back to where it started means no aggregate in
          # it is a boundary anyone can reason about without the rest of
          # the ring, and the whole ring is really one aggregate wearing
          # several names.
          #
          # Checked at the bluebook level, not inside `AggregateBuilder`
          # itself, because seeing a cycle needs every end declared — an
          # aggregate finishes building long before it can know whether
          # some later aggregate in the same file points back at it.
          #
          # ACYCLIC WITHIN A CHAPTER (ADR 0025, "References") — widened
          # from the direct pair (A -> B -> A) this used to catch alone to
          # any ring, however long (A -> B -> C -> A), the same DFS
          # coloring a reference graph needs for any cycle. A cross-chapter
          # reference is UNREACHABLE here rather than unchecked:
          # `Reference#resolve` is scoped to its own chapter by
          # construction, so a target this chapter never declares is a
          # dangling name, not an edge — `edges.key?` below is what keeps
          # the walk from ever leaving this chapter's own aggregates.
          # Self-reference stays legal (`parent.parent.name` for a
          # hierarchy is real and safe) — excluded the same way the
          # direct-pair check already excluded it.
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

          # Plain DFS with a visiting/done coloring, over the reference
          # graph THIS chapter's own aggregates declare. Returns the ring
          # itself (in the order it closes), or nil.
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
              next unless edges.key?(target) # a name this chapter never declares is dangling, not an edge

              found = reference_cycle_from(target, edges, state, path)
              return found if found
            end

            path.pop
            state[node] = :done
            nil
          end

          # THE OTHER HALF OF A HOP — AggregateBuilder#seal_query_field
          # recognised the HEAD of a dotted where-field that names one of
          # its own references and deferred it here, unable to check
          # further: it cannot yet resolve what the reference points AT.
          # This runs once every aggregate exists in one chapter, so it
          # can.
          #
          # Only WHERE clauses ever reach here — a hop on ORDER BY is
          # refused outright, immediately, back in seal_query_field
          # itself (that answer never needed the target's shape).
          #
          # AN ENTITY'S OWN QUERIES DID reach `EntityBuilder#reference_to`
          # (added after this comment first claimed otherwise — S9, ADR
          # 0025) without ever reaching HERE: tier-1 sealing
          # (`AggregateBuilder#query_surfaces`) already recognises a hop
          # on an entity's own field and DEFERS it exactly like an
          # aggregate's, but nothing ever walked entity queries at tier 2
          # to check the deferral — a bad hop, or even a well-formed one,
          # built silently and then matched nothing at runtime
          # (`QueryInterpreter#entity_rows` reads an element's fields by
          # literal hash key, never follows a reference). Refused outright
          # here instead of taught to follow the hop for real: no corpus
          # member needs an entity query to cross a reference yet, and a
          # named refusal beats a runtime that resolves nothing while
          # looking like it might.
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

          # The chapter-wide half of AggregateBuilder's local query-argument
          # inference. A hop cannot resolve while its aggregate is still being
          # built; here every Reference has an owner and target, so a symbolic
          # comparison can inherit the type of the scalar it compares without a
          # duplicate query-local declaration.
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

          # THE LEAF `infer_hop_query_arguments!` INFERS for one resolved
          # hop plan — a pure function of `plan` and the symbolic `name`
          # it is naming, pulled out because it is a self-contained
          # computation with no dependency on the enclosing loop's own
          # iteration state (it neither reads nor mutates anything about
          # `bluebook`/`aggregate`/`query` beyond what `plan` already
          # carries).
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
              # HopPath.plan pushes even an unresolved hop onto `hops`
              # before reporting this, specifically so `target_name` —
              # real, known at declaration, independent of whether
              # `resolve` succeeded — is always here to name.
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

          # The same three-way answer seal_query_field gives for its OWN
          # aggregate's fields — landing on a real scalar (fine), landing
          # on a value object (refused by name), or naming nothing at all
          # (refused by name) — asked instead of the hop's TARGET aggregate,
          # since that is whose shape the tail actually has to answer for.
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

          # A WHERE hop with an ordered comparator is legitimate ("client
          # whose balance > 500") — AggregateBuilder#seal_ordered_comparator
          # already deferred this exact check for the same reason every
          # other hop check is deferred, and this is where it gets asked,
          # against the hop's TARGET instead of the querying aggregate.
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

          # THE TARGET HALF of `projects` validation (S12, ADR 0025) —
          # `AggregateBuilder#seal_projected_fields` already checked the
          # LOCAL half at declare time (the reference names a real
          # `reference_to` on THIS aggregate); this checks the reference
          # actually resolves to a real aggregate in this chapter, and
          # that aggregate really declares `remote_field` as a scalar.
          #
          # Reuses `QuerySpecification::HopPath` rather than re-deriving
          # hop resolution a second way — `"reference/remote_field"` is
          # the same single-hop shape a query's own `/`-spelled hop
          # resolves, even though `projects`'s own DSL spelling is dotted
          # (`from: :"customer.status"`): two constructs, two spellings,
          # one resolution primitive. A single hop can never reach
          # HopPath::MAX_HOPS, so :too_deep is structurally unreachable
          # here and is not special-cased.
          def validate_projected_fields!(bluebook)
            bluebook.aggregates.each do |aggregate|
              aggregate.projected_fields.each { |field| validate_projected_field!(aggregate, field) }
            end
          end

          # A linear decision tree of validation rules over ONE resolved
          # hop plan, each already explained by its own comment above
          # (the lifecycle fallback, the chained-projection fallback, the
          # final scalar check) — a fixed, closed sequence "resolve, then
          # check each way this could legitimately or illegitimately
          # land," not several unrelated concerns. Splitting it would
          # scatter `plan`/`target`/`remote_attribute` across new methods
          # that would each need most of them anyway.
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

            # THE WORKED EXAMPLE ITSELF (ADR 0025) reads through a
            # LIFECYCLE field — banking's Customer.status is `lifecycle
            # :status`, never a plain `attribute` — the same fallback
            # validate_hop_tail! already gives a query's own hop tail. A
            # lifecycle field is always a plain string by construction ;
            # nothing further to check once it matches by name.
            return if remote_attribute.nil? && target.lifecycle&.field.to_s == plan.tail

            # A PROJECTION MAY CHAIN THROUGH ANOTHER PROJECTION (S12, ADR
            # 0025's own boundary rule, followed through) — `target`'s
            # OWN projected fields live in `projected_fields`, a
            # separate list from `attributes`, so a match there is
            # invisible to the check above even though it names a real,
            # always-current, stored field. `Transfer.projects
            # :source_customer_status, from: :"source.customer_status"`
            # reads Account's own already-projected `customer_status`
            # this way — Account is one hop from Customer, Transfer is
            # one hop from Account, and neither aggregate needs to know
            # about the other's target two hops away. A projected
            # field's remote value is always a scalar by construction
            # (`RebuildSweep.remote_value` never copies a reference, a
            # value object, or a list), so nothing further to check once
            # it matches by name — same reasoning the lifecycle
            # fallback just above already applies.
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

          # `correlates_by` NAMES A SCALAR, NOW CHECKED RATHER THAN TRUSTED.
          #
          # ProcessManagerBuilder#validate! already refuses a bare, undotted
          # spelling — a SYNTACTIC guarantee that the declaration cannot leave
          # the question open. It cannot go further: a process manager is built
          # in isolation, before this chapter's aggregates exist to check
          # against. Here, with the whole document assembled, the dotted path
          # is walked for real — against whichever command actually emits an
          # event this process manager reacts to — so a path that still lands
          # on a value object is refused before the runtime ever has to decide
          # what a non-scalar correlation key even means: a saga keys off this
          # value directly, and a value object carries no guaranteed-stable
          # identity to key on the way a scalar does.
          #
          # A command that does not declare the path's first segment at all is
          # silently skipped, not refused — correlation has two other fallback
          # tiers below the payload dig (a correlation stamp, then the emitting
          # aggregate's own reference key; saga_interpreter/correlation.rb), so
          # an absent field is not this check's business. Only a field that
          # resolves, and resolves to something other than a scalar, is.
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

          # Walks the remaining dotted segments through nested value objects.
          # `type_name` starts as the head attribute's own declared type ; each
          # step either bottoms out at a real scalar (nil — no violation) or
          # names why it cannot: still a value object with no more path left,
          # a value object this domain never declared, a field that value
          # object does not have, or a segment left over after already
          # reaching a scalar.
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
