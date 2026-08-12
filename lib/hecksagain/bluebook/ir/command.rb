module Hecksagain
  module Bluebook
    module IR
      Given = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
        include Hecksagain::IR

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

        # An APPEND binds several fields at once, each from either a command
        # ARGUMENT (a Symbol) or a LITERAL. It used to spell the Symbol bare
        # and inspect the rest, which is the opposite of what a where-clause
        # did with the same two kinds — see Hecksagain::Literal.
        def appended_fields = source.transform_values { |value| Literal.render(value) }

        def classified_source
          if source.is_a?(Symbol)
            { kind: "argument", name: source.to_s }
          else
            { kind: "literal", value: source }
          end
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
      # `acts_on` answers with the owning construct itself — the IR::Aggregate,
      # or the entity holder for a piece's verb — rather than the name of one.
      # The invocation door (`pizza.add_topping`) is the facade's business, a
      # per-boot projection ; no verb method is defined here.
      class Command
        extend Construct
        extend Hecksagain::IR

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
            # Indexed once — attributes are final once absorbed, and every
            # dispatch asks this finder by name.
            @attributes_by_name = attributes.to_h { |held| [held.name, held] }
          end

          # The construct this verb acts upon — the construct itself, not its name.
          #
          # A verb declared on an ENTITY always acts on that piece. It never
          # self-references, because an element is addressed THROUGH its parent —
          # which means `creates?` answers true for every one of them, and reading
          # `acts_on` off `creates?` alone would report that `LedgerEntry.Amend`
          # brings a ledger entry into being. Three of banking's commands were
          # about to say exactly that, and nothing would have contradicted them.
          #
          # On an aggregate, a creating command acts on no existing root, so nil is
          # the truth: there is nothing there yet.
          def acts_on
            return hecks_owner if hecks_owner.is_a?(Class) && hecks_owner < Entity

            creates? ? nil : hecks_owner
          end

          def creates? = @references.nil?

          def attribute(named) = @attributes_by_name[named.to_sym]

        end
      end
    end
  end
end
