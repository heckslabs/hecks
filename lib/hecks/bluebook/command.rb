require_relative "behaviour/command"
require_relative "../vocabulary"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    Given = Struct.new(:description, :canonical, :predicate, :ast, keyword_init: true)

    Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
      include Hecks::IR
      include Behaviour::Mutation

      # `sign:` — item #5 of the whole-project table-unification survey. Reads
      # `Vocabulary::MutationOp` directly (plain data, no framework dependency
      # — safe during parsing, same reason `RuleReference`'s own bootstrap
      # concerns don't apply here) rather than requiring `Runtime::CommandRules`
      # from the bluebook/IR layer, which would be a real layering inversion
      # (runtime depends on bluebook, not the reverse), and rather than
      # independently re-deriving `increment`/`decrement`'s own +1/-1 from the
      # op name in two Rust codegen scripts (rust/project/mutations.rb,
      # rust/codegen/src/mutations.rs), duplicating what
      # `Runtime::CommandRules::Arithmetic::MUTATION_OPS` already tables off
      # this same generated `Vocabulary::MutationOp` data. `""` (not nil) for
      # ops with no sign, matching every other optional IR text field's own
      # absent-is-empty-string convention.
      #
      # @param oper [String, Symbol] the mutation operation's name, such as `"increment"`
      # @return [String] the op's sign (`"+"`/`"-"`), or `""` if the op has none
      def self.sign_for(oper)
        Hecks::Vocabulary.rows("MutationOp").find { |row| row["name"] == oper.to_s }&.fetch("sign", "") || ""
      end

      emits_ir(target: :target, op: :op, sign: -> { Mutation.sign_for(op) })

      # The one genuinely branching emission in the model: an append (or a
      # delegate — `CommandBuilder#delegates_to`'s own comment gives the
      # full reasoning for reusing this exact wire shape rather than
      # inventing a parallel one) binds several fields at once and carries
      # `fields:`, everything else carries a single `source:`. Declared
      # emission covers the fixed head; `super` supplies it and this adds
      # the tail, which is why a construct with a variable shape needs no
      # new mixin API.
      #
      # @return [Hash] the declared emission, plus `fields:` (each target field's rendered
      #   source) for `append`/`delegate`/`corrects`, or `source:` (the classified source)
      #   for every other op
      def to_h
        return super.merge(fields: appended_fields) if [:append, :delegate, :corrects].include?(op)

        super.merge(source: classified_source)
      end
    end

    # A command, as a Ruby class.
    #
    # Not nested as a constant, and that is a finding rather than a shortcut. A
    # command and a value object may legitimately share a name inside one
    # aggregate — the language does it six times, and means it: the command
    # `Argument` is the verb that appends to the `arguments` list whose element
    # type is the value object `Argument`, and `Plan` reads exactly that pairing.
    # So `Bluebook::Command::Argument` cannot be both, and a single constant
    # namespace cannot index a kind-ambiguous name. The same follows for
    # `hecks_fqn` : `Bluebook::Command.Argument` names both, which is why the judge's
    # ids only work per-category, each in its own repository. Identity is
    # (kind, FQN), not fqn.
    #
    # It is a declaration holder anyway, because that is where the edges live.
    # `acts_on` answers with the owning construct itself — the Aggregate,
    # or the entity holder for a piece's verb — rather than the name of one.
    # The invocation door (`pizza.add_topping`) is the facade's business, a
    # per-boot projection ; no verb method is defined here.
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
        mutations:  many(:mutations),
        emits:      :emits,
        # The lifecycle state this command is admissible from (S10, ADR
        # 0025 — "lifecycle state becomes a command guard") — a guard,
        # not a transition: `command "Debit", from: "open"` replaces
        # `given("account is open") { status == "open" }`, checked
        # against the owning construct's own lifecycle field the same
        # way `admissible_transition` already checks a real state
        # change, but names no target state and moves nothing. Nil for
        # a command with no such guard — most commands.
        from:       -> { from },
        provenance: :provenance
      )

      class << self
        attr_reader :role, :goal, :attributes, :givens, :ensures, :mutations, :emits, :references,
                    :from, :provenance

        # Mints a new verb class for one declared command and absorbs its fields into it.
        #
        # @param name [String, Symbol] the command's declared name
        # @param role [String, Symbol, nil] the command's declared responsibility, or `nil`
        #   if it declares none
        # @param goal [String, nil] the command's declared human-readable description
        # @param attributes [Array<Bluebook::Attribute>] the command's declared arguments
        # @param givens [Array<Bluebook::Given>] the admissibility rules that must hold
        #   before this command runs
        # @param ensures [Array<Bluebook::Given>] the rules that must hold after this
        #   command runs
        # @param mutations [Array<Bluebook::Mutation>] the field mutations this command
        #   applies
        # @param emits [Array<String>] the events this command declares it emits
        # @param references [String, Symbol, nil] the aggregate this command
        #   self-addresses or cross-references, or `nil` for a creating command
        # @param from [String, Array<String>, nil] the lifecycle state(s), or state, this
        #   command is admissible from, or `nil` for no such guard
        # @param provenance [Object, nil] the command's declared canonical source, captured
        #   exactly as written, or `nil` if it declares none
        # @return [Class] the minted verb class (a `Bluebook::Command` subclass)
        def declare(name:, role: nil, goal: nil, attributes: [], givens: [], ensures: [],
                    mutations: [], emits: [], references: nil, from: nil, provenance: nil)
          verb = Class.new(self)
          verb.hecks_name = name.to_s
          verb.absorb(role: role, goal: goal, attributes: attributes, givens: givens,
                      ensures: ensures, mutations: mutations, emits: emits, references: references&.to_s,
                      from: from, provenance: provenance)
          verb
        end

        # Assigns what the language declares onto this verb class, then hands off to
        # `Behaviour::Command#settle`.
        #
        # @param role [String, Symbol, nil] see `declare`
        # @param goal [String, nil] see `declare`
        # @param attributes [Array<Bluebook::Attribute>] see `declare`
        # @param givens [Array<Bluebook::Given>] see `declare`
        # @param ensures [Array<Bluebook::Given>] see `declare`
        # @param mutations [Array<Bluebook::Mutation>] see `declare`
        # @param emits [Array<String>] see `declare`
        # @param references [String, nil] see `declare`
        # @param from [String, Array<String>, nil] see `declare`
        # @param provenance [Object, nil] see `declare`
        # @return [Class] this verb's own class, self, once its attributes are indexed
        def absorb(role:, goal:, attributes:, givens:, ensures:, mutations:, emits:, references:,
                   from: nil, provenance: nil)
          @role       = role
          @goal       = goal
          @attributes = attributes
          @givens     = givens
          @ensures    = ensures
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
