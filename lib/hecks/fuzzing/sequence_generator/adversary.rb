require_relative "../invalid_value_generator"
require_relative "../value_generator"
require_relative "../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Adversarial argument mutations, the shapes Ruby/Rust divergences were found through.
      # Off at `adversarial: 0.0`, which returns before any RNG draw.
      module Adversary
        KINDS = %i[
          routing_key
          blank_identity
          null_value_object
          duplicate_entity_identity
          omit_mapped_argument
          refusal_precedence
        ].freeze

        # `to`/`with` are the dispatcher's routing keywords and `id` the untyped identity fallback;
        # each is offered as bare null, a scalar, or a routing-shaped object.
        ROUTING_KEYS   = %w[to with id].freeze
        ROUTING_SHAPES = %w[null scalar route].freeze

        # A creating command's own identity part, blank three ways.
        BLANK_SHAPES = %w[empty whitespace null].freeze

        # A single-field value object as bare `null` and as `{}`.
        VALUE_OBJECT_SHAPES = %w[null empty_object].freeze

        # An unknown key, a type-mismatched key and an absent required key in one step, so both
        # engines must pick which refusal wins. The second row reaches later `DISPATCH_ORDER`
        # stages (lib/hecks/vocabulary.rb): `nonexistent` addresses an id nothing holds,
        # `lifecycle` aims a transition-guarded command at a real record, `role` binds a caller
        # the command does not name.
        PRECEDENCE_SHAPES = %w[
          unknown+mismatch+absent unknown+absent unknown+mismatch mismatch+absent
          nonexistent+mismatch nonexistent+unknown lifecycle+mismatch role+absent role+nonexistent
        ].freeze

        # A drawn caller on a role-gated command, separate from `KINDS` (`role_draw:`) so it
        # composes with any argument mutation and draws nothing when off.
        #   matching         the command's own role
        #   mismatched       another declared role, or none the domain knows
        #   absent_on_gated  no caller at all: the unchecked default, recorded as a control
        #   actor_known      the role plus an actor this sequence already granted it
        #   actor_unknown    the role plus an actor nothing granted
        CALLER_SHAPES = %w[matching mismatched absent_on_gated actor_known actor_unknown].freeze
        UNKNOWN_ROLE  = "Nobody the domain names".freeze

        # An entity command two or more hops deep, addressed by flat one-head-per-hop args or the
        # routed `to: { aggregate:, entities: [...] }` envelope. picker.rb weights these up.
        DEEP_ENTITY_DEPTH  = 2
        DEEP_ENTITY_WEIGHT = 4

        # Needs an element this sequence already appended, a rare moment, so it is weighted up
        # when on offer.
        DUPLICATE_IDENTITY_WEIGHT = 3

        private

        def adversarial? = @adversarial.positive?

        # `[]` with no RNG draw when adversarial mode is off; otherwise the deep-entity note, then
        # with probability `@adversarial` one mutation applicable to this step.
        def adversarial_mutations!(args, entry, catalog)
          return [] unless adversarial?

          mutations = []
          mutations << deep_entity_addressing!(args, entry) if (entry[:chain] || []).size >= DEEP_ENTITY_DEPTH
          return mutations if @random.rand >= @adversarial

          applicable = KINDS.select { |kind| send(:"#{kind}_applicable?", args, entry, catalog) }
          return mutations if applicable.empty?

          weighted = applicable.flat_map { |kind| [kind] * (kind == :duplicate_entity_identity ? DUPLICATE_IDENTITY_WEIGHT : 1) }
          mutations << send(:"apply_#{weighted.sample(random: @random)}!", args, entry, catalog)
        end

        def deep_entity_addressing!(args, entry)
          depth  = entry[:chain].size
          routed = @random.rand(2).zero?
          note   = { "mutation" => "deep_entity", "bug" => "BUG#11", "depth" => depth,
                     "addressing" => routed ? "routed" : "flat" }
          return note unless routed

          heads   = [entry[:aggregate], *entry[:chain]].map { |construct| (construct.identified_by || :id).to_s }
          scalars = heads.map { |head| ValueGenerator.scalar_of(args[head]) }
          # The heads leave the flat args unless the command declares an attribute of that name
          # (chess's `Piece.Move` declares `id`); dropping that would be a different mutation.
          heads.each { |head| args.delete(head) unless entry[:command].attribute(head) }
          args["to"] = { "aggregate" => scalars.first, "entities" => scalars.drop(1) }
          note
        end

        # Not applied over a routed `to:` from `deep_entity_addressing!`; overwriting it would
        # contradict that step's note.
        def routing_key_applicable?(args, _entry, _catalog) = !args.key?("to")

        def apply_routing_key!(args, entry, _catalog)
          key   = ROUTING_KEYS.sample(random: @random)
          shape = ROUTING_SHAPES.sample(random: @random)
          args[key] =
            case shape
            when "null"   then nil
            when "scalar" then routing_scalar(args, entry)
            else               routing_object(args, entry)
            end
          { "mutation" => "routing_key", "bug" => "BUG#7/#16/#8", "key" => key, "shape" => shape,
            "declared" => !entry[:command].attribute(key).nil? }
        end

        # This step's own parent id, an out-of-range Integer, or a minted id nothing holds.
        def routing_scalar(args, entry)
          case @random.rand(3)
          when 0 then parent_scalar_of(args, entry)
          when 1 then ValueGenerator::INTEGER_EDGE_CASES.sample(random: @random)
          else        ValueGenerator.random_id(@random)
          end
        end

        def routing_object(args, entry)
          entities = (entry[:chain] || []).map { |piece| ValueGenerator.scalar_of(args[(piece.identified_by || :id).to_s]) }
          # Half the time one identity too many, a depth the verb lacks, which both engines must
          # refuse alike.
          entities << ValueGenerator.random_id(@random) if @random.rand(2).zero?
          { "aggregate" => parent_scalar_of(args, entry), "entities" => entities }
        end

        def parent_scalar_of(args, entry)
          key = (entry[:aggregate].identified_by || :id).to_s
          args.key?(key) ? ValueGenerator.scalar_of(args[key]) : identity_scalar_of(entry[:aggregate], args)
        end

        def blank_identity_applicable?(args, entry, catalog) = blank_identity_targets(args, entry, catalog).any?

        # Identity heads this step supplies: a creating command's own (every composite part) and
        # an append's entity identity arguments.
        def blank_identity_targets(args, entry, catalog)
          targets = []
          if entry[:entity].nil? && entry[:command].creates?
            aggregate = entry[:aggregate]
            heads = composite_identity?(aggregate) ? aggregate.identity_heads : [aggregate.identified_by || :id]
            targets.concat(heads.map(&:to_s))
          end
          populator = populator_for_entry(catalog, entry)
          targets.concat(populator[:identity_arguments].map(&:to_s)) if populator
          targets.uniq.select { |head| args.key?(head) }
        end

        def apply_blank_identity!(args, entry, catalog)
          head  = blank_identity_targets(args, entry, catalog).sample(random: @random)
          shape = BLANK_SHAPES.sample(random: @random)
          blank = shape == "empty" ? "" : "   "
          args[head] =
            if shape == "null" then nil
            elsif args[head].is_a?(Hash) then args[head].transform_values { blank }
            else blank
            end
          { "mutation" => "blank_identity", "bug" => "BUG#15", "argument" => head, "shape" => shape }
        end

        def null_value_object_applicable?(args, entry, _catalog) = value_object_targets(args, entry).any?

        def value_object_targets(args, entry)
          aggregate = entry[:aggregate]
          entry[:command].attributes.reject { |attribute| attribute.list? || attribute.reference? }
                         .select { |attribute| args.key?(attribute.name.to_s) }
                         .filter_map do |attribute|
            value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
            [attribute, value_object] if value_object&.sole_attribute
          end
        end

        def apply_null_value_object!(args, entry, _catalog)
          targets = value_object_targets(args, entry)
          closed  = targets.select { |_, value_object| value_object.closed_set? }
          attribute, value_object = (closed.empty? ? targets : closed).sample(random: @random)
          shape = VALUE_OBJECT_SHAPES.sample(random: @random)
          args[attribute.name.to_s] = shape == "null" ? nil : {}
          { "mutation" => "null_value_object", "bug" => "BUG#14", "argument" => attribute.name.to_s,
            "value_object" => value_object.hecks_name, "closed_set" => value_object.closed_set? == true,
            "shape" => shape }
        end

        def duplicate_entity_identity_applicable?(args, entry, catalog) = duplicate_identity_pool(args, entry, catalog).any?

        def duplicate_identity_pool(args, entry, catalog)
          populator = populator_for_entry(catalog, entry)
          return [] unless populator && populator[:identity_arguments].any?

          @appended_identities[append_pool_key(populator, args)]
        end

        def apply_duplicate_entity_identity!(args, entry, catalog)
          populator = populator_for_entry(catalog, entry)
          tuple     = duplicate_identity_pool(args, entry, catalog).sample(random: @random)
          args.merge!(tuple)
          { "mutation" => "duplicate_entity_identity", "bug" => "BUG#13", "entity" => populator[:entity].hecks_name,
            "composite" => populator[:identity_arguments].size > 1, "identity" => tuple }
        end

        def omit_mapped_argument_applicable?(args, entry, _catalog) = mapped_argument_targets(args, entry).any?

        # An append's mapped source arguments, or a plain creating command's non-identity
        # attributes; never an identity head.
        def mapped_argument_targets(args, entry)
          command = entry[:command]
          heads   = identity_heads_of(entry)
          mapped  = command.mutations.select { |mutation| mutation.op == :append }
                           .flat_map { |mutation| mutation.source.values.grep(Symbol).map(&:to_s) }
          if mapped.empty? && !entry.key?(:entity) && command.creates?
            mapped = command.attributes.map { |attribute| attribute.name.to_s }
          end
          command.attributes.select do |attribute|
            name = attribute.name.to_s
            mapped.include?(name) && args.key?(name) && !heads.include?(name)
          end
        end

        def apply_omit_mapped_argument!(args, entry, _catalog)
          attribute = mapped_argument_targets(args, entry).sample(random: @random)
          args.delete(attribute.name.to_s)
          { "mutation" => "omit_mapped_argument", "bug" => "BUG#12", "argument" => attribute.name.to_s,
            "optional" => attribute.optional? == true }
        end

        def refusal_precedence_applicable?(args, entry, _catalog)
          precedence_shapes_for(args, entry).any?
        end

        # Every shape whose parts this step can carry. `nonexistent` and `lifecycle` need a
        # record-addressing command with flat addressing; `lifecycle` also a guarded command;
        # `role` a declared role.
        def precedence_shapes_for(args, entry)
          can = {
            "mismatch"    => corruptible_attributes(args, entry).any?,
            "absent"      => droppable_required_attributes(args, entry).any?,
            "unknown"     => true,
            "nonexistent" => acts_on_record?(args, entry),
            "lifecycle"   => acts_on_record?(args, entry) && transition_guarded?(entry),
            "role"        => !entry[:command].role.to_s.empty?
          }
          PRECEDENCE_SHAPES.select { |shape| shape.split("+").all? { |part| can.fetch(part) } }
        end

        def acts_on_record?(args, entry) = !entry[:command].creates? && !args.key?("to")

        def transition_guarded?(entry)
          command = entry[:command]
          owner   = entry.key?(:entity) ? entry[:entity] : entry[:aggregate]
          return true if command.from
          return false unless owner.respond_to?(:lifecycle)

          owner.lifecycle&.transitions_for(command.hecks_name)&.any? || false
        end

        def apply_refusal_precedence!(args, entry, catalog)
          corruptible = corruptible_attributes(args, entry)
          droppable   = droppable_required_attributes(args, entry)
          wanted      = precedence_shapes_for(args, entry).sample(random: @random).split("+")
          detail      = { "mutation" => "refusal_precedence", "bug" => "BUG#7/#8/#14" }
          applied     = []

          if wanted.include?("absent")
            dropped = droppable.sample(random: @random)
            args.delete(dropped.name.to_s)
            detail["absent"] = dropped.name.to_s
            applied << "absent"
            corruptible -= [dropped]
          end
          if wanted.include?("mismatch") && corruptible.any?
            attribute = corruptible.sample(random: @random)
            args[attribute.name.to_s] = InvalidValueGenerator.corrupt(attribute, entry[:aggregate], random: @random)
            detail["mismatched"] = attribute.name.to_s
            applied << "mismatch"
          end
          if wanted.include?("unknown")
            name, value = InvalidValueGenerator.undeclared_argument(random: @random)
            args[name] = value
            detail["unknown"] = name
            applied << "unknown"
          end
          apply_late_stage_parts!(wanted, args, entry, detail, applied, catalog)
          # Reported as what was done: a single-attribute command cannot carry both a drop and a
          # corruption.
          detail.merge("shape" => applied.sort.join("+"))
        end

        # The parts past the argument gate. `nonexistent` re-addresses the last hop to an id
        # nothing holds; `lifecycle` mutates nothing and is recorded so the pairing is visible;
        # `role` parks a mismatched caller for StepBuilder to bind around the dispatch.
        def apply_late_stage_parts!(wanted, args, entry, detail, applied, catalog)
          if wanted.include?("nonexistent")
            piece = (entry[:chain] || []).last || entry[:aggregate]
            head  = (piece.identified_by || :id).to_s
            args[head] = identity_shaped(piece, piece.identified_by, ValueGenerator.random_id(@random), entry[:aggregate])
            detail["nonexistent"] = head
            applied << "nonexistent"
          end
          if wanted.include?("lifecycle")
            detail["lifecycle"] = entry[:command].from || "transition-guarded"
            applied << "lifecycle"
          end
          return unless wanted.include?("role")

          @precedence_caller = { "role" => other_role(entry[:command].role.to_s, catalog) }
          detail["role"] = @precedence_caller["role"]
          applied << "role"
        end

        def role_draw? = @role_draw.positive?

        # `[caller, note]`: the caller StepBuilder binds around the dispatch (nil for the unchecked
        # control) and the note for the step's `"adversarial"` metadata. A caller parked by
        # `refusal_precedence` wins; an ungated command draws nothing.
        def caller_draw!(entry, catalog)
          if @precedence_caller
            caller = @precedence_caller
            @precedence_caller = nil
            return [caller, nil]
          end

          role = entry[:command].role.to_s
          return [nil, nil] if !role_draw? || role.empty? || @random.rand >= @role_draw

          shapes = CALLER_SHAPES.dup
          shapes.delete("actor_known") if @granted[role].empty?
          shape  = shapes.sample(random: @random)
          caller = caller_for_shape(shape, role, catalog)
          note   = { "mutation" => "caller_role", "angle" => "ANGLE-5", "shape" => shape, "gated_role" => role }
          [caller, caller ? note.merge(caller) : note]
        end

        def caller_for_shape(shape, role, catalog)
          case shape
          when "matching"      then { "role" => role }
          when "mismatched"    then { "role" => other_role(role, catalog) }
          when "actor_known"   then { "role" => role, "actor_id" => @granted[role].sample(random: @random) }
          when "actor_unknown" then { "role" => role, "actor_id" => ValueGenerator.random_id(@random) }
          end
        end

        # Another declared role when there is one (a real wrong hat), else a role none names.
        def other_role(role, catalog)
          others = catalog[:roles] - [role]
          others.empty? ? UNKNOWN_ROLE : others.sample(random: @random)
        end

        def corruptible_attributes(args, entry)
          entry[:command].attributes.reject(&:list?).select { |attribute| args.key?(attribute.name.to_s) }
        end

        def droppable_required_attributes(args, entry)
          heads = identity_heads_of(entry)
          entry[:command].attributes.reject(&:optional?).select do |attribute|
            args.key?(attribute.name.to_s) && !heads.include?(attribute.name.to_s)
          end
        end

        # Aims a grant at a role some command declares; random role text would make `actor_known`
        # unreachable. Does nothing without the role draw.
        def steer_grant!(args, entry, catalog)
          return unless role_draw? && catalog[:grant_verbs].include?(entry[:verb]) && catalog[:roles].any?
          return unless args.key?("role_name")

          args["role_name"] = { "value" => catalog[:roles].sample(random: @random) }
        end

        def populator_for_entry(catalog, entry)
          owner = entry.key?(:entity) ? entry[:entity] : entry[:aggregate]
          catalog[:populators].find { |p| p[:command].equal?(entry[:command]) && p[:owner].equal?(owner) }
        end

        # Every identity head this step addresses by: the aggregate's own, the untyped `id`, and
        # one per entity hop.
        def identity_heads_of(entry)
          heads = entry[:aggregate].identity_heads.map(&:to_s) + ["id"]
          (entry[:chain] || []).each { |piece| heads.concat(piece.identity_heads.map(&:to_s)) }
          heads.uniq
        end
      end
    end
  end
end
