require_relative "behaviour/command"
require_relative "../vocabulary"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    Given = Struct.new(:description, :canonical, :predicate, :ast, keyword_init: true)

    Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
      include Hecks::IR
      include Behaviour::Mutation

      # Reads `Vocabulary::MutationOp` directly: runtime depends on bluebook, not the reverse.
      # Answers "" rather than nil, like every optional IR text field.
      #
      # @param oper [String, Symbol] the mutation's operation name, such as
      #   `"increment"` or `"decrement"`
      # @return [String] the operation's sign from `Vocabulary::MutationOp`
      #   (`"+"` or `"-"`), or `""` when the op has none or is not found
      def self.sign_for(oper)
        Hecks::Vocabulary.rows("MutationOp").find { |row| row["name"] == oper.to_s }&.fetch("sign", "") || ""
      end

      emits_ir(target: :target, op: :op, sign: -> { Mutation.sign_for(op) })

      # An append, delegate or correction binds several fields and carries `fields:`;
      # every other op carries a single `source:`.
      #
      # @return [Hash{Symbol => Object}] the declared emission — `super`'s fixed
      #   head, plus `fields:` (a Hash of bound field values) for an
      #   append-shaped op, or `source:` (`classified_source`'s own result) for
      #   any other
      def to_h
        return super.merge(fields: appended_fields) if [:append, :delegate, :corrects].include?(op)

        super.merge(source: classified_source)
      end
    end

    # A declared command, minted as its own anonymous class.
    #
    # Not a nested constant: a command and a value object may share a name in one aggregate,
    # so identity is (kind, FQN), not the name alone.
    class Command
      extend Construct
      extend Hecks::IR
      extend Behaviour::Command

      emits_ir(
        name:       :hecks_name,
        role:       :role,
        goal:       :goal,
        references: :references,
        attributes: many(:attributes),
        givens:     -> { givens.map { |rule| Expression::AstJson.rule_row(rule) } },
        ensures:    -> { ensures.map { |rule| Expression::AstJson.rule_row(rule) } },
        needs:      -> { needs.map { |fact| { fact: fact.to_s } } },
        mutations:  many(:mutations),
        emits:      :emits,
        # The lifecycle state this command is admissible from: a guard, not a transition.
        from:       -> { from },
        provenance: :provenance
      )

      class << self
        attr_reader :role, :goal, :attributes, :givens, :ensures, :needs, :mutations, :emits, :references,
                    :from, :provenance

        # Mints one command as its own anonymous subclass of the class `declare` is called on.
        #
        # @param name [String, Symbol] the command's declared name
        # @param role [String, nil] the declared role text; `goal` is the goal text
        # @param attributes [Array<Bluebook::Attribute>] the declared arguments
        # @param givens [Array<Bluebook::Given>] the declared preconditions
        # @param ensures [Array<Bluebook::Given>] the postconditions; `needs` the facts it supplies
        # @param mutations [Array<Bluebook::Mutation>] the state changes it applies
        # @param emits [Array<String>] the event names it may emit
        # @param references [String, Symbol, nil] the aggregate its `reference_to` addresses
        # @param from [String, Array<String>, nil] the lifecycle states it is admissible from
        # @param provenance [Object, nil] the declared canonical source, as written
        def declare(name:, role: nil, goal: nil, attributes: [], givens: [], ensures: [], needs: [],
                    mutations: [], emits: [], references: nil, from: nil, provenance: nil)
          verb = Class.new(self)
          verb.hecks_name = name.to_s
          verb.absorb(role: role, goal: goal, attributes: attributes, givens: givens,
                      ensures: ensures, needs: needs, mutations: mutations, emits: emits, references: references&.to_s,
                      from: from, provenance: provenance)
          verb
        end

        # Assigns what the language declares, then `settle` indexes the attributes.
        #
        # Takes the keywords `declare` takes, minus `name`.
        #
        # @return [Class] self
        def absorb(role:, goal:, attributes:, givens:, ensures:, mutations:, emits:, references:,
                   needs: [], from: nil, provenance: nil)
          @role       = role
          @goal       = goal
          @attributes = attributes
          @givens     = givens
          @ensures    = ensures
          @needs      = needs
          @mutations  = mutations
          @emits      = emits
          @references = references
          @from       = from
          @provenance = provenance
          settle
        end
      end
    end
  end
end
