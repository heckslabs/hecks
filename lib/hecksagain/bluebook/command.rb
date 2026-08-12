require_relative "behaviour/command"

module Hecksagain
  module Bluebook
    Given = Struct.new(:description, :canonical, :predicate, keyword_init: true)

    Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
      include Hecksagain::IR
      include Behaviour::Mutation

      emits_ir(target: :target, op: :op)

      # THE ONE GENUINELY BRANCHING EMISSION in the model: an append
      # binds several fields at once and carries `fields:`, everything
      # else carries a single `source:`. Declared emission covers the
      # fixed head; `super` supplies it and this adds the tail, which
      # is why a construct with a variable shape needs no new mixin API.
      def to_h
        return super.merge(fields: appended_fields) if op == :append

        super.merge(source: classified_source)
      end

    end

    # A command, as a RUBY CLASS.
    #
    # NOT nested as a constant, and that is a finding rather than a shortcut. A
    # command and a value object may legitimately share a name inside one
    # aggregate — the language does it six times, and means it: the command
    # `Argument` is the verb that appends to the `arguments` list whose element
    # type is the value object `Argument`, and `Plan` reads exactly that pairing.
    # So `Bluebook::Command::Argument` cannot be both, and a single constant
    # namespace cannot index a kind-ambiguous name. The same follows for
    # `hecks_fqn` : `Bluebook::Command.Argument` names both, which is why the judge's
    # ids only work per-category, each in its own repository. IDENTITY IS
    # (KIND, FQN), not fqn.
    #
    # It is a declaration holder anyway, because that is where the EDGES live.
    # `acts_on` answers with the owning construct itself — the Aggregate,
    # or the entity holder for a piece's verb — rather than the name of one.
    # The invocation door (`pizza.add_topping`) is the facade's business, a
    # per-boot projection ; no verb method is defined here.
    class Command
      extend Construct
      extend Hecksagain::IR
      extend Behaviour::Command

      emits_ir(
        name:       :hecks_name,
        role:       :role,
        goal:       :goal,
        references: :references,
        attributes: many(:attributes),
        givens:     -> { givens.map { |rule| { description: rule.description, canonical: rule.canonical } } },
        ensures:    -> { ensures.map { |rule| { description: rule.description, canonical: rule.canonical } } },
        mutations:  many(:mutations),
        emits:      :emits,
        provenance: :provenance
      )

      class << self
        attr_reader :role, :goal, :attributes, :givens, :ensures, :mutations, :emits, :references,
                    :provenance

        def declare(name:, role: nil, goal: nil, attributes: [], givens: [], ensures: [],
                    mutations: [], emits: [], references: nil, provenance: nil)
          verb = Class.new(self)
          verb.hecks_name = name.to_s
          verb.absorb(role: role, goal: goal, attributes: attributes, givens: givens,
                      ensures: ensures, mutations: mutations, emits: emits, references: references&.to_s,
                      provenance: provenance)
          verb
        end

        def absorb(role:, goal:, attributes:, givens:, ensures:, mutations:, emits:, references:,
                   provenance: nil)
          @role       = role
          @goal       = goal
          @attributes = attributes
          @givens     = givens
          @ensures    = ensures
          @mutations  = mutations
          @emits      = emits
          @references = references
          @provenance = provenance
          settle
        end


      end
    end
  end
end
