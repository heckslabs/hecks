require_relative "../invalid_value_generator"
require_relative "../value_generator"
require_relative "../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # THE ARGUMENT SHAPES THE RUBY/RUST DIVERGENCES WERE ACTUALLY FOUND
      # THROUGH, injected on purpose, on every domain.
      #
      # Ten bugs in one QA session (BUG#7–#16, `QualityControl`'s own
      # ledger) clustered in a handful of mechanisms — and several were
      # only ever reachable because ONE domain happened to declare the
      # argument that tripped them: `Roster::Roster.Mark`'s own `to:`
      # collided with the dispatcher's routing `to:` (BUG#7), a present-
      # but-null `to:` was misread as a routing envelope (BUG#16), a blank
      # creating identity minted a phantom aggregate in Rust (BUG#15), a
      # single-field closed-set argument offered as bare `null` refused
      # with different KINDS on the two engines (BUG#14). No other domain
      # in the rotation could ever have found any of those, because
      # nothing generated ever produced the shape. This module produces
      # them — for a configurable fraction of command steps, chosen and
      # parameterised from the SAME seeded RNG the rest of the generator
      # already draws from, so `generate(domain, seed:, steps:,
      # adversarial:)` stays exactly as reproducible per seed as it was.
      #
      # OPT-IN, BY CONSTRUCTION. `adversarial: 0.0` (the default) returns
      # before drawing a single random number, so every pinned seed in
      # spec/fuzzing, spec/rust_conformance_fuzz_spec.rb, bin/fuzz and
      # bin/generate produces byte-for-byte what it produced before this
      # module existed. `bin/qa_sweep` turns it on (reading
      # `QualityControlDials::ADVERSARIAL_FRACTION`) — that script is the
      # one place a mutated step's own divergence is a FINDING rather than
      # a red CI gate.
      #
      # ONE MUTATION PER STEP, applied in `StepBuilder#build_command_step`
      # after the arguments and identity are built and BEFORE the step's
      # own inline dispatch — so the generator's own `known_ids` tracking
      # sees what really happened, and so the returned step's `args` ARE
      # the mutated bytes both `Fuzzing::Replay` (Ruby) and the compiled
      # conformance binary (Rust) later receive. The step carries an
      # `"adversarial"` key naming what was done (`mutation`, the bug
      # class it exercises, and the exact sub-shape), which `bin/qa_sweep`
      # prints on a FOUND SOMETHING report so the agent logging the Bug
      # can name the mechanism, not guess it. Both replay paths ignore
      # the key: `Replay.call` reads only verb/query/dry_run/args/role,
      # and `kernel/cli.rs` reads step keys by name.
      module Adversary
        KINDS = %i[
          routing_key
          blank_identity
          null_value_object
          duplicate_entity_identity
          omit_mapped_argument
          refusal_precedence
        ].freeze

        # BUG#7/#16/#8 — `to`/`with` are `Dispatcher#dispatch`'s own
        # routing keywords (Ruby's kwarg binding steals them from a flat
        # args hash; Rust's `CommandInvocation::from_json` reads the same
        # two names off the same object), `id` is the untyped identity
        # fallback `ArgumentGate#refuse_unknown_arguments` exempts. Three
        # shapes each: bare null (BUG#16), a scalar (BUG#7's out-of-range
        # Integer among them), and the routing-shaped object.
        ROUTING_KEYS   = %w[to with id].freeze
        ROUTING_SHAPES = %w[null scalar route].freeze

        # BUG#15 — a creating command's own identity part, blank three ways.
        BLANK_SHAPES = %w[empty whitespace null].freeze

        # BUG#14 — a single-field value object as bare `null` and as `{}`.
        VALUE_OBJECT_SHAPES = %w[null empty_object].freeze

        # BUG#7/#8/#14's class — an unknown key, a type-mismatched declared
        # key and an absent required key in the SAME step, so both engines
        # have to pick which refusal wins; and each pair, so the ordering
        # of any two is observable on a command too small for all three.
        #
        # THE SECOND ROW REACHES FURTHER DOWN `DISPATCH_ORDER`
        # (lib/hecks/vocabulary.rb): `nonexistent` addresses an id nothing
        # holds (a `hydrate`-stage NotFound), `lifecycle` aims a
        # transition-guarded command at a real record (an
        # `admissible_transition`-stage refusal, IF the record's state
        # refuses it), `role` binds a caller whose role the command does
        # not name (the `refuse_role_mismatch` stage no generated step
        # had ever reached). Paired with an argument-stage fault each,
        # so the ordering of an EARLY stage against a LATE one is
        # observable — BUG#13 (ledger_ordering's own NOTES.md) was
        # exactly an argument-invariant-vs-entity-existence ordering
        # split, and nothing generated had ever asked the question on
        # purpose.
        PRECEDENCE_SHAPES = %w[
          unknown+mismatch+absent unknown+absent unknown+mismatch mismatch+absent
          nonexistent+mismatch nonexistent+unknown lifecycle+mismatch role+absent role+nonexistent
        ].freeze

        # ITEM 2 OF THE DETECTION PLAN (ANGLE-5) — A DRAWN CALLER ON A
        # ROLE-GATED COMMAND. `refuse_role_mismatch` is a `DISPATCH_ORDER`
        # step both engines implement (`command_rules/authorization.rb`,
        # `rust/src/kernel/repository.rs check_role`) and both replay doors
        # already read (`Fuzzing::Replay` binds `Hecks.as_caller` from a
        # step's `role:`/`actor_id:`; `kernel/cli.rs` reads the same two
        # keys) — yet no generated step ever carried either key, so the
        # check was dormant on every sweep ever run. Five shapes:
        #   matching        the command's own role — the string fallback
        #                   authorizes it on both engines
        #   mismatched      another declared role (or none the domain
        #                   knows) — Unauthorized on both
        #   absent_on_gated no caller at all on a gated command — the
        #                   unchecked default, recorded so the step reads
        #                   as a deliberate control, not an omission
        #   actor_known     the role PLUS an actor this same sequence
        #                   already granted it to (`Governance::
        #                   RoleAssignment.Assign` succeeded earlier) —
        #                   the real `holds_role?` lookup, both sides
        #   actor_unknown   the role plus an actor nothing granted —
        #                   `holds_role?` must refuse on both
        # A SEPARATE LAYER FROM `KINDS`, with its own probability
        # (`role_draw:` — `QualityControlDials::ROLE_DRAW_PROBABILITY`):
        # a caller composes with any argument mutation above rather than
        # competing with it for the one-mutation-per-step slot, and draws
        # nothing from the RNG when off, so every pinned seed is
        # byte-identical to before it existed.
        CALLER_SHAPES = %w[matching mismatched absent_on_gated actor_known actor_unknown].freeze
        GRANT_VERB    = "Governance::RoleAssignment.Assign".freeze
        UNKNOWN_ROLE  = "Nobody the domain names".freeze

        # BUG#11 — an entity command two or more hops deep. Not a mutation
        # of arguments but a PREFERENCE (picker.rb weights these up when
        # adversarial) plus an addressing coin: flat one-head-per-hop args
        # (what every other generated entity step uses) or the routed
        # `to: { aggregate:, entities: [...] }` envelope BUG#11's own fix
        # was scoped to. The step's metadata reports the depth reached
        # so a depth-3 domain is visibly exercised there.
        DEEP_ENTITY_DEPTH  = 2
        DEEP_ENTITY_WEIGHT = 4

        # BUG#13's mutation is only ever applicable on a step whose
        # parent ALREADY holds an element this same sequence appended —
        # a rare moment (an append has to have succeeded first, and most
        # mutated appends are refused), so when it is on offer it is
        # weighted up the same way the picker weights an unexercised
        # verb: the opportunity is what is scarce, not the kind.
        DUPLICATE_IDENTITY_WEIGHT = 3

        private

        def adversarial? = @adversarial.positive?

        # `[]` — and NO RNG DRAW — when adversarial mode is off. Otherwise
        # the deep-entity addressing note (every deep step, when
        # adversarial), then with probability `@adversarial` exactly one
        # mutation among those applicable to THIS step's own command.
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

        # ── BUG#11: depth ≥ 2 entity command, flat or routed addressing ──

        def deep_entity_addressing!(args, entry)
          depth  = entry[:chain].size
          routed = @random.rand(2).zero?
          note   = { "mutation" => "deep_entity", "bug" => "BUG#11", "depth" => depth,
                     "addressing" => routed ? "routed" : "flat" }
          return note unless routed

          heads   = [entry[:aggregate], *entry[:chain]].map { |construct| (construct.identified_by || :id).to_s }
          scalars = heads.map { |head| ValueGenerator.scalar_of(args[head]) }
          # The heads leave the flat args — this is the CLEAN routed
          # caller BUG#11's own spec pins (`to: {...}, note: {...}`) —
          # unless the command itself declares an attribute of that name
          # (chess's `Piece.Move` declares `id` as a fact too), which
          # stays because dropping it would be a different mutation.
          heads.each { |head| args.delete(head) unless entry[:command].attribute(head) }
          args["to"] = { "aggregate" => scalars.first, "entities" => scalars.drop(1) }
          note
        end

        # ── BUG#7/#16/#8: an undeclared routing/identity key on flat args ──

        # Not on a step already carrying a routed `to:` from
        # `deep_entity_addressing!` — overwriting that envelope would
        # leave the deep-entity note claiming an addressing the args no
        # longer have.
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

        # A real-looking id (this step's own parent, so a routed envelope
        # can actually resolve), BUG#7's own out-of-range Integer, or a
        # minted id nothing holds.
        def routing_scalar(args, entry)
          case @random.rand(3)
          when 0 then parent_scalar_of(args, entry)
          when 1 then ValueGenerator::INTEGER_EDGE_CASES.sample(random: @random)
          else        ValueGenerator.random_id(@random)
          end
        end

        def routing_object(args, entry)
          entities = (entry[:chain] || []).map { |piece| ValueGenerator.scalar_of(args[(piece.identified_by || :id).to_s]) }
          # Half the time one identity too many — a depth the verb does
          # not have, which `Routing.envelope`'s `entity_depth` check and
          # Rust's own envelope parser must both refuse the same way.
          entities << ValueGenerator.random_id(@random) if @random.rand(2).zero?
          { "aggregate" => parent_scalar_of(args, entry), "entities" => entities }
        end

        def parent_scalar_of(args, entry)
          key = (entry[:aggregate].identified_by || :id).to_s
          args.key?(key) ? ValueGenerator.scalar_of(args[key]) : identity_scalar_of(entry[:aggregate], args)
        end

        # ── BUG#15: a blank identity part on a creating step ──────────────

        def blank_identity_applicable?(args, entry, catalog) = blank_identity_targets(args, entry, catalog).any?

        # The identity heads THIS step supplies itself: a creating
        # aggregate command's own (every part of a composite), and an
        # append's caller-supplied entity identity arguments (an entity is
        # "created" by its append, and BUG#15's blank-identity question
        # applies there too).
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

        # ── BUG#14: a single-field value object as null / {} ─────────────

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

        # ── BUG#13: an entity identity this sequence already appended ────

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

        # ── BUG#12: a mapped/declared attribute left out of the payload ──

        def omit_mapped_argument_applicable?(args, entry, _catalog) = mapped_argument_targets(args, entry).any?

        # For an append: the arguments its `append:` mapping sources (the
        # element's own declared fields). For a plain creating command:
        # every declared non-identity attribute. Never an identity head —
        # that is `blank_identity`'s question, not this one.
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

        # ── BUG#7/#8/#14: unknown + mismatched + absent, in one step ─────

        def refusal_precedence_applicable?(args, entry, _catalog)
          precedence_shapes_for(args, entry).any?
        end

        # EVERY SHAPE WHOSE EVERY PART THIS STEP CAN CARRY. `nonexistent`
        # and `lifecycle` need a command that ACTS on a record (a creating
        # step has no addressed id to point elsewhere, and no state to be
        # in) and flat addressing (`deep_entity_addressing!`'s routed `to:`
        # envelope owns the ids then); `lifecycle` additionally needs a
        # command some guard actually watches; `role` needs a declared
        # `role` to mismatch against.
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
          # Reported as what was ACTUALLY done — a command with a single
          # attribute cannot carry both a dropped and a corrupted one.
          detail.merge("shape" => applied.sort.join("+"))
        end

        # The three parts that reach PAST the argument gate — see
        # `PRECEDENCE_SHAPES`' own second row. `nonexistent` re-addresses
        # the step's LAST hop (the entity element for an entity command,
        # the aggregate itself otherwise) to an id nothing holds;
        # `lifecycle` mutates nothing (the record's own state is what
        # refuses, or doesn't) and is recorded so the pairing is visible;
        # `role` parks a mismatched caller for `StepBuilder` to bind
        # around this one dispatch.
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

        # ── ANGLE-5: a drawn caller on a role-gated command ──────────────

        def role_draw? = @role_draw.positive?

        # `[caller, note]` — `caller` is the `{"role" => …, "actor_id" =>
        # …}` pair (or nil for the unchecked control) `StepBuilder` binds
        # around the step's one dispatch and writes onto the step itself;
        # `note` rides in the step's `"adversarial"` metadata. A
        # `refusal_precedence` mutation that already parked a caller for
        # this step wins outright (its whole point is that pairing); an
        # ungated command draws nothing (there is no role to match or
        # mismatch), and with the draw off nothing is drawn at all.
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

        # Another role the domain itself declares, when it has one — a
        # real "wrong hat", the more interesting mismatch — else a role no
        # bluebook names at all.
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

        # A GRANT AIMED AT A ROLE SOME COMMAND ACTUALLY DECLARES. Left to
        # `ValueGenerator`, `Assign`'s `role_name` is random text
        # ("hotel"), which no command is gated on — so a granted actor
        # could never satisfy `holds_role?` for anything, and the
        # `actor_known` shape above would be unreachable by construction.
        # With the draw on, every generated grant names one of the
        # domain's own declared roles instead; with it off, nothing here
        # runs (no RNG draw, no change to the args).
        def steer_grant!(args, entry, catalog)
          return unless role_draw? && entry[:verb] == GRANT_VERB && catalog[:roles].any?
          return unless args.key?("role_name")

          args["role_name"] = { "value" => catalog[:roles].sample(random: @random) }
        end

        # ── shared ───────────────────────────────────────────────────────

        def populator_for_entry(catalog, entry)
          owner = entry.key?(:entity) ? entry[:entity] : entry[:aggregate]
          catalog[:populators].find { |p| p[:command].equal?(entry[:command]) && p[:owner].equal?(owner) }
        end

        # Every identity head this step addresses by: the aggregate's own
        # (plus the untyped `id` fallback) and one per entity hop.
        def identity_heads_of(entry)
          heads = entry[:aggregate].identity_heads.map(&:to_s) + ["id"]
          (entry[:chain] || []).each { |piece| heads.concat(piece.identity_heads.map(&:to_s)) }
          heads.uniq
        end
      end
    end
  end
end
