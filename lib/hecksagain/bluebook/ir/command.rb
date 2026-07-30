module Hecksagain
  module Bluebook
    module IR
      Given = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
        def to_h
          base = { target: target, op: op }
          return base.merge(fields: appended_fields) if op == :append

          base.merge(source: classified_source)
        end

        def appended_fields
          source.transform_values do |value|
            value.is_a?(Symbol) ? value.to_s : value.inspect
          end
        end

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
      # So `Meta::Command::Argument` cannot be both, and a single constant
      # namespace cannot index a kind-ambiguous name. The same follows for
      # `hecks_fqn` : `Meta::Command.Argument` names both, which is why the judge's
      # ids only work per-category, each in its own repository. IDENTITY IS
      # (KIND, FQN), not fqn.
      #
      # It is a class anyway, because that is where the EDGES live. `acts_on`
      # answers with the aggregate class rather than the name of one, and the
      # invocation door was never going to be a constant — `pizza.add_topping` is
      # already the method the builder defines.
      class Command
        extend Construct

        class << self
          attr_reader :role, :goal, :attributes, :givens, :mutations, :emits, :references

          def declare(name:, role: nil, goal: nil, attributes: [], givens: [],
                      mutations: [], emits: [], references: nil)
            verb = Class.new(self)
            verb.hecks_name = name.to_s
            verb.absorb(role: role, goal: goal, attributes: attributes, givens: givens,
                        mutations: mutations, emits: emits, references: references&.to_s)
            verb
          end

          def absorb(role:, goal:, attributes:, givens:, mutations:, emits:, references:)
            @role       = role
            @goal       = goal
            @attributes = attributes
            @givens     = givens
            @mutations  = mutations
            @emits      = emits
            @references = references
          end

          # The construct this verb acts upon — the class, not its name.
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

          def attribute(named) = attributes.find { |held| held.name == named.to_sym }

          def to_h
            {
              name:       hecks_name,
              role:       role,
              goal:       goal,
              references: references,
              attributes: attributes.map(&:to_h),
              givens:     givens.map { |rule| { description: rule.description, canonical: rule.canonical } },
              mutations:  mutations.map(&:to_h),
              emits:      emits
            }
          end
        end
      end
    end
  end
end
