module Hecks
  module Bluebook
    module MetaValidator
      # What the language says about ITSELF, read back as something walkable.
      #
      # The judge used to carry one hand-written branch per category, and the
      # reason given for keeping it that way was that "which append command
      # belongs to which list is not derivable from a name". True — and beside
      # the point. It is derivable from the language's own IR, because every
      # append command DECLARES its target:
      #
      #     command "Argument" do
      #       reference_to Command
      #       then_set :arguments, append: { name: :name, type: :type, ... }
      #     end
      #
      # That one line says both things a walk needs: `Command.Argument` is the
      # appender for the `arguments` list, and the map binds each value-object
      # field to the command argument that fills it. Nothing is matched by name.
      #
      # The same reading recovers the containment tree. A command with NO
      # self-reference is the creating one, and the `*_id` argument it carries
      # names the parent — so Bluebook -> Aggregate -> Command / ValueObject /
      # Query / Entity, ValueObject -> Member, ProcessManager -> Handler ->
      # Dispatch all fall out of the declarations rather than being restated here.
      #
      # Usage:
      #
      #     plan = Plan.for(MetaValidator.grammar_registry)
      #     plan.category("Command").parent            # => "Aggregate"
      #     plan.category("Command").appends["rules"]  # => Append(verb: "Rule", map: {...})
      #     plan.verbs                                 # every Bluebook:: verb declared
      #
      # This reads the language. It does not read a bluebook and it dispatches
      # nothing — that is the judge's job.
      class Plan
        # One append command: the verb, and the value-object-field -> argument map.
        # `:map` shadows Enumerable#map on purpose — `spec/plan_spec.rb`
        # itself asserts `appends["emits"].map` reads the field (a Hash),
        # not an Enumerable#map result. Verified before disabling this cop.
        # rubocop:disable-next Lint/StructNewOverride
        Append = Struct.new(:verb, :map, keyword_init: true)

        # One setting command. `targets` is target -> argument ; Lifecycle sets two
        # fields in a single command, so it is a map rather than a pair.
        Setter = Struct.new(:verb, :targets, keyword_init: true)

        Category = Struct.new(:name, :declare, :parent, :parent_key, :fields,
                              :appends, :alternates, :setters, :sealers, :references,
                              :identity_paths, :entity_owned,
                              keyword_init: true) do
          # Every verb this category declares, in declaration order. `alternates`
          # matters here: two commands can append to one list, and a verb missing
          # from this is a verb the coverage gate stops watching.
          def verbs
            [declare, *setters.map(&:verb), *appends.values.map(&:verb),
             *alternates.map(&:verb), *sealers].compact
          end

          # DOES THIS ARGUMENT CARRY AN ID? A reference is the id of a head, and
          # an id is a scalar — so the judge offers it bare, where every other
          # field goes as a one-field value object. The language answers this
          # about itself, so declaring a new reference needs no change here.
          def references?(verb, argument)
            Array(references[verb.to_s]).include?(argument.to_s)
          end

          def root? = parent.nil?
        end

        def self.for(registry)
          new(registry.bluebook("Bluebook"))
        end

        attr_reader :categories

        def initialize(meta)
          @categories = {}
          meta.aggregates.each do |aggregate|
            # Vocabulary declares no commands — it is static declaration read from
            # the IR by spec/vocabulary_conformance_spec, never dispatched. It needs
            # no special case: a category with nothing to offer contributes nothing.
            next if aggregate.commands.empty?

            @categories[aggregate.hecks_name] = read(aggregate)

            # S17, ADR 0026 — Member/Handler/Dispatch are ENTITIES now
            # (`entity "Member" do ... end`, nested under `ValueObject`/
            # `ProcessManager`/`Handler`), not their own top-level
            # aggregates — so `meta.aggregates` alone no longer finds
            # them the way it always found a standalone `aggregate
            # "Member"`. Each STILL needs its own named category here:
            # `Assembly::Contracts` keeps a bespoke entry for each
            # (Member's own open-map `pairs`, Dispatch's own open-map
            # `with_spec`), distinct from the single generic "Entity"
            # category every ORDINARY real-corpus entity (LedgerEntry,
            # Withdrawal, ...) is described through instead. Safe to
            # walk EVERY meta-domain aggregate's own `.entities`
            # unconditionally — `Plan` only ever reads the META-
            # DOMAIN'S OWN self-description (`Plan.for(MetaValidator.
            # grammar_registry)`), which never declares a generic,
            # nameless entity of its own the way a REAL domain's
            # `LedgerEntry` is; the only entities the meta-domain
            # itself ever declares are exactly the three this ADR
            # names. `entity_owned: true` records WHY this is a
            # category at all — the real runtime has no top-level
            # aggregate named "Member" to dispatch a BARE verb into
            # any more, so the judge has to build a DOTTED one instead
            # (see `Judge#verb_for`).
            #
            # RECURSES — `Dispatch` nests inside `Handler`, which nests
            # inside `ProcessManager`, two levels deep, not one. Each
            # nested entity's own `parent` names the DIRECT owner it was
            # actually found under (Dispatch's is "Handler", not
            # "ProcessManager") — `read`'s own `owner:` argument already
            # takes whichever name is passed, so walking one level deeper
            # each recursive call is the whole change; nothing about
            # `read` itself needed to know how deep it was called from.
            add_nested_entities(aggregate)
          end
          @categories.freeze
        end

        def category(name) = @categories[name.to_s]
        def names          = @categories.keys

        # Every verb the language declares, spelled as the judge would
        # dispatch it. S17, ADR 0026 — an ENTITY-OWNED category (its
        # own `entity_owned` flag) has no real top-level aggregate the
        # runtime can route a BARE verb into any more, so it is
        # spelled DOTTED here too — `Bluebook::ValueObject.Member.
        # Declare`, `Bluebook::ProcessManager.Handler.Dispatch.Bind` —
        # matching `Judge#verb_for`/`#dotted_prefix`'s own build
        # exactly (recursing the same way, for the same reason: an
        # entity-owned category's own parent may itself be entity-
        # owned), so this stays what it already is: the judge's own
        # coverage promise, not a second guess at it.
        def verbs
          @categories.flat_map do |name, category|
            category.verbs.map { |verb| "Bluebook::#{dotted_prefix(name)}.#{verb}" }
          end
        end

        private

        # Walks one construct's own `.entities`, recursing into each
        # found entity's own `.entities` in turn — S17, ADR 0026's
        # two-level chain (`Dispatch`, inside `Handler`, inside
        # `ProcessManager`). `owner` is passed down explicitly rather
        # than re-derived, because it names whichever construct THIS
        # call actually found the entity under — the DIRECT parent, not
        # the root.
        def add_nested_entities(owner)
          owner.entities.each do |entity|
            next if entity.commands.empty?

            @categories[entity.hecks_name] = read(entity, owner: owner.hecks_name, entity_owned: true)
            add_nested_entities(entity)
          end
        end

        # THE FULL DOTTED PREFIX a category's own verbs hang off —
        # mirrors `Judge#dotted_prefix` exactly (S17, ADR 0026): the
        # plain name for an ordinary category, or its PARENT's own
        # prefix with this category's name appended, for an entity-
        # owned one, recursing because the parent may itself be
        # entity-owned.
        def dotted_prefix(name)
          found = category(name)
          return name unless found&.entity_owned

          "#{dotted_prefix(found.parent)}.#{name}"
        end

        # `owner:`/`entity_owned:` — S17, ADR 0026. An AGGREGATE-level
        # creating command carries its own parent as a `reference_to`
        # argument (read via `parent_reference_of` below), the same
        # way it always has. An ENTITY-level one never does — `entity
        # "Member" do ... end`'s own creating command reaches its
        # parent through the DOTTED CALL itself (`ValueObject.Member.
        # Declare`), the same reason an ordinary entity's own commands
        # never declare `reference_to` either (entity.md's own
        # reference page states this). So the OWNING aggregate's name
        # is passed in directly here, by the caller who already knows
        # it (the same `.entities` walk that found this node), rather
        # than derived from an argument that was never going to be
        # there.
        def read(aggregate, owner: nil, entity_owned: false)
          # An ENTITY-OWNED category has no creating command of its own to find.
          # `creating_command` tests `command.references.nil?` — the same test
          # a REAL entity's own commands pass too, since `entity "Member" do
          # command "Pair" ... end end` never writes `reference_to` (an
          # entity's commands never do — banking's own LedgerEntry.Amend
          # doesn't either). Calling it here would have it seize on Member's
          # own "Pair" and call THAT the creating command, which it is not:
          # a Member is created by `ValueObject.Member`, its OWNER's own bare
          # append command, the same way a real LedgerEntry is created by
          # `Account.LogEntry`, never by a dotted verb of its own.
          declare    = entity_owned ? nil : declaration_command(aggregate)
          parent     = parent_relationship_of(aggregate)
          parent_key = owner ? "aggregate" : parent&.name&.to_s
          rest       = aggregate.commands - [declare].compact

          Category.new(
            name:           aggregate.hecks_name,
            declare:        declare&.hecks_name,
            parent:         owner || parent&.type&.target_name,
            parent_key:     parent_key,
            fields:         declared_fields(declare),
            appends:        appends_in(rest),
            alternates:     alternates_in(rest),
            setters:        setters_in(rest),
            sealers:        sealers_in(rest),
            # EVERY command, not `rest` — the creating command carries the parent
            # link, which is the most common reference of all.
            references:     references_in(aggregate.commands),
            # HOW THE CATEGORY NAMES ITS RECORDS, read from the language rather
            # than restated. The judge has to know a record's id BEFORE it
            # dispatches, because the children it walks next carry it as their
            # parent — so it derives the same join the runtime will, off the same
            # declaration. It used to be a branch per category, and a branch that
            # disagreed with the runtime by one separator was a broken reference.
            identity_paths: aggregate.identity_paths,
            entity_owned:   entity_owned
          )
        end

        # Which arguments of which verbs carry an ID rather than a value, read
        # straight from the language's own IR.
        def references_in(commands)
          commands.each_with_object({}) do |command, found|
            named = command.attributes.select(&:reference?).map { |attribute| attribute.name.to_s }
            found[command.hecks_name] = named unless named.empty?
          end
        end

        # The declaration command establishes the record's declared identity.
        # Receiver references never carried that meaning; entity-owned categories
        # prove it because every one of their commands lacks such a marker. The
        # identity-write rule is structural and remains true after routing moves
        # entirely into `to:`. `owner_id` is traversal context rather than stored
        # state, so the declaration establishes every remaining identity head.
        def declaration_command(aggregate)
          required = aggregate.identity_heads.map(&:to_sym) - [:owner_id]
          candidates = aggregate.commands.select do |command|
            targets = Array(command.mutations).map { |mutation| mutation.target.to_sym }
            required.all? { |field| targets.include?(field) }
          end

          return candidates.first if candidates.one?

          raise DSL::Malformed,
                "#{aggregate.hecks_name} must declare exactly one command that establishes " \
                "its identity fields #{required.join(', ')} — found #{candidates.map(&:hecks_name).join(', ')}"
        end

        # Containment belongs to stored aggregate structure. The first declared
        # structural relationship is the traversal parent; command arguments may
        # carry its identity as an ordinary value object, but do not define it.
        def parent_relationship_of(aggregate)
          aggregate.attributes.find(&:reference?)
        end

        # What the creating command sets directly. EVERY reference
        # argument is dropped, not just the parent link: a reference is
        # not a field. Command.Declare carries `entity_id` as well as
        # the parent `aggregate` reference, because an entity declares
        # commands too, and offering either as a field would have the
        # walk hand it a name instead of a head.
        def declared_fields(declare)
          return [] unless declare

          declare.attributes.reject(&:reference?).map { |attribute| attribute.name.to_s }
        end

        # list attribute -> the command that appends to it, and how its arguments map.
        def appends_in(commands)
          commands.each_with_object({}) do |command, found|
            Array(command.mutations).each do |mutation|
              next unless mutation.op == :append

              # FIRST wins, not last. Two commands can append to the same list —
              # Aggregate.Attribute and Aggregate.Reference both extend `attributes`,
              # because a reference's type is not a value object and cannot go
              # through the same verb. Overwriting would have let the one declared
              # later silently displace the other, and the walk would have offered
              # every ordinary attribute as a reference.
              found[mutation.target.to_s] ||= Append.new(verb: command.hecks_name, map: mutation.source)
            end
          end
        end

        # The appenders DISPLACED by first-wins — Aggregate.Reference behind
        # Aggregate.Attribute. The walk reaches them by reading the row, not the
        # plan, but they are still verbs the language declares and the coverage
        # gate has to see them.
        def alternates_in(commands)
          claimed = {}
          commands.flat_map do |command|
            Array(command.mutations).filter_map do |mutation|
              next unless mutation.op == :append

              target = mutation.target.to_s
              if claimed[target]
                Append.new(verb: command.hecks_name, map: mutation.source)
              else
                claimed[target] = true
                nil
              end
            end
          end
        end

        # Commands that SET rather than append. Lifecycle sets two targets at once,
        # so a setter is keyed by its verb and carries every target it writes.
        def setters_in(commands)
          commands.filter_map do |command|
            targets = Array(command.mutations)
                      .select { |mutation| mutation.op == :set }
                      .to_h { |mutation| [mutation.target.to_s, mutation.source.to_s] }
            next if targets.empty?

            Setter.new(verb: command.hecks_name, targets: targets)
          end
        end

        # Commands that change nothing — they exist to be REFUSED. Aggregate.Seal is
        # the whole-document check: dispatched once everything is declared, carrying
        # only givens. A category with no sealer simply has no such rule.
        def sealers_in(commands)
          commands.select { |command| Array(command.mutations).empty? }.map(&:hecks_name)
        end
      end
    end
  end
end
