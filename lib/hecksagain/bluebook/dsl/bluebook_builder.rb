module Hecksagain
  module Bluebook
    module DSL
      class BluebookBuilder
        attr_reader :classification

        def initialize(name, version: nil)
          @name       = name
          @version    = version
          @aggregates       = []
          @read_models      = []
          @policies         = []
          @process_managers = []
        end

        def vision(value)
          # moved to the language: Vision invariant, on Chapter.Declare

          @vision = value
        end

        # A domain's own identity can change — this names what it used to
        # be, so the storage layer can recognize its own history under the
        # old name instead of minting a brand-new lineage from nothing.
        def formerly_known_as(value) = @formerly_known_as = value.to_s

        def core       = @classification = :core
        def supporting = @classification = :supporting
        def generic    = @classification = :generic

        def aggregate(name, &block)
          @aggregates << AggregateBuilder.build(name, &block)
        end

        # `read_model` is the word (ADR 0025 reverts `report` — the IR
        # construct, the registry API, and the docs filename all said
        # `read_model` the whole time; no era was ever minted under
        # `report`, so this is history and source agreeing again). `report`
        # stays answered under `MetaValidator.shadow_parsing?` (S0a's own
        # bridge) for the same reason `has_many` does — frozen era text
        # that used it must keep booting; live source refuses it, naming
        # the replacement.
        def read_model(name, &block)
          # A read model gathers heads from SEVERAL aggregates, so no single head
          # declares it — the chapter does. Its owner is stamped in `build`, where
          # the chapter namespace exists.
          @read_models << ReadModelBuilder.build(name, &block)
        end

        def report(name, &block)
          return read_model(name, &block) if MetaValidator.shadow_parsing?

          raise Malformed, "report is gone — read_model is the word now"
        end

        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        def process_manager(name, &block)
          @process_managers << ProcessManagerBuilder.build(name, &block)
        end

        def build
          # moved to the language: an attribute type is a reference to its Shape,
          # so an undeclared value object fails reference resolution
          validate_reference_value_objects!
          validate_correlation_keys!
          validate_no_bidirectional_references!
          policies = @aggregates.flat_map(&:policies) + @policies

          # The chapter is the top of the construct chain — `Bluebook` is a
          # ROOT, and its constructor stamps every aggregate and read model with
          # itself as owner, so every `hecks_fqn` below resolves by walking up
          # to it. No constants are installed at load time : the public door is
          # a per-boot projection, installed by `Loader.bind_runtime` once a
          # dispatcher exists to close over (facade/surface.rb).
          bluebook = Bluebook::Chapter.new(name: @name, version: @version, vision: @vision,
                                      aggregates: @aggregates,
                                      read_models: @read_models,
                                      policies: policies,
                                      process_managers: @process_managers,
                                      classification: @classification,
                                      formerly_known_as: @formerly_known_as)

          # Every hop AggregateBuilder#seal_query_field recognised and
          # deferred gets checked for real here — the earliest point a
          # hop CAN be checked, for exactly the reason
          # validate_no_bidirectional_references! above already gives:
          # `Bluebook.new` just stamped `hecks_owner` on every
          # aggregate, so `Reference#resolve` finally has a chapter to
          # walk. Before this line every target in the file (including
          # ones declared ABOVE the aggregate doing the asking) would
          # have resolved to nil.
          validate_query_hops!(bluebook)

          # The language judges the bluebook, in the language. Last, so the
          # meta-domain sees a fully built IR — the whole-document rules need
          # every declaration present, which is why they cannot be givens fired
          # at declaration time.
          MetaValidator.call(bluebook)
        end

        private

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
        def validate_reference_value_objects!
          heads = @aggregates.map(&:hecks_name)

          violations = @aggregates.flat_map do |aggregate|
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
        def validate_no_bidirectional_references!
          edges = @aggregates.each_with_object({}) do |aggregate, index|
            index[aggregate.hecks_name] = aggregate.reference_targets.uniq.reject { |target| target == aggregate.hecks_name }
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
        # itself (that answer never needed the target's shape). An
        # entity's own queries never reach here either, structurally:
        # an entity has no `reference_to` at all, so
        # HopPath.hop_head? can never answer true for one of its
        # fields, and nothing about them was ever deferred to begin
        # with.
        def validate_query_hops!(bluebook)
          bluebook.aggregates.each do |aggregate|
            aggregate.queries.each do |query|
              query.wheres.each do |clause|
                next unless QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)

                validate_hop_clause!(aggregate, query, clause)
              end
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
        def validate_correlation_keys!
          @process_managers.each do |pm|
            next unless pm.correlates_by

            reason = correlation_key_violation(pm)
            next unless reason

            raise ProcessManagerBuilder::InvalidProcessManager,
                  "#{pm.name} correlates_by #{pm.correlates_by.inspect}, but #{reason}"
          end
        end

        def correlation_key_violation(pm)
          head, *rest = pm.correlates_by.to_s.split(".")
          events = reacted_events(pm)

          emitting_commands(events).each do |owner, command|
            attribute = command.attributes.find { |a| a.name == head.to_sym }
            next unless attribute

            reason = list_or_scalar_violation(owner, attribute, rest)
            return reason if reason
          end

          nil
        end

        def reacted_events(pm)
          ([pm.starts_on, pm.ends_on] + pm.handlers.map(&:event_type))
            .compact
            .reject { |event| event == ProcessManager::REFUSED }
            .map { |event| event.to_s.split("::").last }
            .uniq
        end

        def emitting_commands(events)
          @aggregates.flat_map do |aggregate|
            commands = aggregate.commands + aggregate.entities.flat_map(&:commands)
            commands.select { |command| (command.emits.map(&:to_s) & events).any? }
                    .map { |command| [aggregate, command] }
          end
        end

        def list_or_scalar_violation(owner, attribute, segments)
          return "#{attribute.name} is a list — a correlation key must name one instance's own field, " \
                 "not a whole collection" if attribute.list?

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
          return "#{type_name}.#{segment} is a list — a correlation key must name one instance's own field, " \
                 "not a whole collection" if attribute.list?

          walk_scalar(owner, attribute.type.to_s, rest)
        end

        # A CHAPTER MAY BE DECLARED IN SEVERAL FILES, meant to merge into ONE
        # domain — `lib/hecksagain/language/bluebook/*.bluebook` all open
        # `Hecks.bluebook "Bluebook" do ... end`. Each `Hecks.bluebook` call used to
        # mint a fresh builder, so a second file with the same chapter name
        # silently replaced the first's aggregates instead of adding to them.
        #
        # The registry now holds the builder OPEN across calls : the first file
        # for a name creates it, every later file for the same name reuses the
        # same instance, so `@aggregates`/`@read_models` accumulate. `#build` is
        # safe to call once per file on the same builder — it constructs a fresh
        # `Bluebook` from whatever is currently held and re-`Namespace.install`s
        # over the previous one, so the LAST file's call leaves every aggregate
        # seen so far reachable, and each call's IR is a strict superset of the
        # one before. `Registry#add_bluebook` still simply stores by name — with
        # this in place, "last write wins" is the cumulative, correct write.
        def self.build(name, version: nil, &block)
          registry = Hecksagain.current_registry
          builder  = registry ? registry.bluebook_builder(name) { new(name, version: version) } : new(name, version: version)
          # A bare constant in a bluebook — `attribute :name, PizzaName` — is a NAME,
          # not a reference to something Ruby has heard of. `const_missing` hands
          # over a `ConstShim::ScopedConstant` (S0b, const_shim.rb's own comment),
          # and that is still the whole answer for a bare name: `Attribute` spells
          # it with `to_s`, so the `TypeName` wrapper this used to build existed
          # only long enough to be stringified. The concept still has a home — the
          # language declares `value_object "TypeName"` — it just needed no Ruby
          # class of its own. A Module rather than a Symbol is what also lets
          # `Account::Debit`/`admits: Account::LedgerDirection` answer their OWN
          # `::` — a plain Symbol cannot.
          resolver = ->(const) { ConstShim::ScopedConstant.for(const) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
