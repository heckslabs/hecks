require_relative "../value_generator"
require_relative "adversary/argument_mutations"
require_relative "adversary/caller_draw"
require_relative "adversary/identity_mutations"
require_relative "adversary/precedence_mutations"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Adversarial argument mutations, the shapes Ruby/Rust divergences were found through.
      # Off at `adversarial: 0.0`, which returns before any RNG draw.
      module Adversary
        include ArgumentMutations
        include CallerDraw
        include IdentityMutations
        include PrecedenceMutations

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

          kind = drawn_kind(args, entry, catalog)
          mutations << send(:"apply_#{kind}!", args, entry, catalog) if kind
          mutations
        end

        # One kind applicable to this step, with `duplicate_entity_identity` weighted up; nil when
        # none applies.
        def drawn_kind(args, entry, catalog)
          applicable = KINDS.select { |kind| send(:"#{kind}_applicable?", args, entry, catalog) }
          return nil if applicable.empty?

          weighted = applicable.flat_map { |kind| [kind] * (kind == :duplicate_entity_identity ? DUPLICATE_IDENTITY_WEIGHT : 1) }
          weighted.sample(random: @random)
        end

        def deep_entity_addressing!(args, entry)
          depth  = entry[:chain].size
          routed = @random.rand(2).zero?
          note   = { "mutation" => "deep_entity", "bug" => "BUG#11", "depth" => depth,
                     "addressing" => routed ? "routed" : "flat" }
          route_deep_entity!(args, entry) if routed
          note
        end

        def route_deep_entity!(args, entry)
          heads   = [entry[:aggregate], *entry[:chain]].map { |construct| (construct.identified_by || :id).to_s }
          scalars = heads.map { |head| ValueGenerator.scalar_of(args[head]) }
          # The heads leave the flat args unless the command declares an attribute of that name
          # (chess's `Piece.Move` declares `id`); dropping that would be a different mutation.
          heads.each { |head| args.delete(head) unless entry[:command].attribute(head) }
          args["to"] = { "aggregate" => scalars.first, "entities" => scalars.drop(1) }
        end

        # The facts the command `needs`: the runtime answers them when a step leaves them out
        # (each engine from its own clock), so a recorded step carries them and dropping one is not
        # an absent-argument case.
        def needed_facts_of(entry) = entry[:command].needs.map(&:to_s)

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
