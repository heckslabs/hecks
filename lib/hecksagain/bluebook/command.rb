require_relative "behaviour/command"
require_relative "../vocabulary"

module Hecksagain
  module Bluebook
    Given = Struct.new(:description, :canonical, :predicate, keyword_init: true)

    Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
      include Hecksagain::IR
      include Behaviour::Mutation

      # `sign:` — item #5 of the whole-project table-unification survey.
      # `increment`/`decrement`'s own +1/-1 used to be re-derived from the
      # op NAME by two independent Rust codegen scripts (rust/project/
      # mutations.rb, rust/codegen/src/mutations.rs — a ternary on
      # `op == "increment"` in each), even though the fact was already
      # table-driven on the Ruby runtime side
      # (Runtime::CommandRules::Arithmetic::MUTATION_OPS, held equal to
      # Vocabulary::MutationOp by spec/vocabulary_conformance_spec.rb).
      # Reads `Vocabulary::MutationOp` directly (plain data, no framework
      # dependency — safe during parsing, same reason `RuleReference`'s
      # own bootstrap concerns don't apply here) rather than requiring
      # Runtime::CommandRules from the bluebook/IR layer, which would be a
      # real layering inversion (runtime depends on bluebook, not the
      # reverse). "" (not nil) for ops with no sign, matching every other
      # optional IR text field's own absent-is-empty-string convention.
      def self.sign_for(op)
        Hecksagain::Vocabulary.rows("MutationOp").find { |row| row["name"] == op.to_s }&.fetch("sign", "") || ""
      end

      emits_ir(target: :target, op: :op, sign: -> { Mutation.sign_for(op) })

      # THE ONE GENUINELY BRANCHING EMISSION in the model: an append (or a
      # DELEGATE — `CommandBuilder#delegates_to`'s own comment gives the
      # full reasoning for reusing this exact wire shape rather than
      # inventing a parallel one) binds several fields at once and carries
      # `fields:`, everything else carries a single `source:`. Declared
      # emission covers the fixed head; `super` supplies it and this adds
      # the tail, which is why a construct with a variable shape needs no
      # new mixin API.
      def to_h
        return super.merge(fields: appended_fields) if op == :append || op == :delegate

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
        # THE LIFECYCLE STATE THIS COMMAND IS ADMISSIBLE FROM (S10, ADR
        # 0025 — "lifecycle state becomes a command guard") — a GUARD,
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

        def declare(name:, role: nil, goal: nil, attributes: [], givens: [], ensures: [],
                    mutations: [], emits: [], references: nil, from: nil, provenance: nil)
          verb = Class.new(self)
          verb.hecks_name = name.to_s
          verb.absorb(role: role, goal: goal, attributes: attributes, givens: givens,
                      ensures: ensures, mutations: mutations, emits: emits, references: references&.to_s,
                      from: from, provenance: provenance)
          verb
        end

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
