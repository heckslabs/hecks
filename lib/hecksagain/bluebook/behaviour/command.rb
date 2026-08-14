require_relative "traits"

module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A COMMAND DOES. EXTENDED, not included — a command is a
      # CLASS, one per declared verb.
      module Command
        include Indexed

        # Indexed once — attributes are final once absorbed, and every
        # dispatch asks this finder by name.
        def settle
          index_attributes(@attributes)
          self
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
          # FULLY QUALIFIED, and it has to be: inside `module Behaviour`
          # the bare name `Entity` resolves to Behaviour::Entity — this
          # module's SIBLING — not to the construct. Comparing a Class to
          # a Module answers nil, so the guard silently fell through and
          # every entity verb reported acting on nothing.
          return hecks_owner if hecks_owner.is_a?(Class) && hecks_owner < Bluebook::Entity

          creates? ? nil : hecks_owner
        end

        def creates? = @references.nil?

        # EVERY REASON THIS VERB CAN REFUSE ON A RULE — the descriptions of
        # its givens AND its ensures, the exact text the runtime quotes
        # after "refused — " when a guard is not met (see
        # command_rules/admissibility.rb's GivenNotMet/EnsuresNotMet). A
        # property that asks "did the runtime only ever refuse for a rule
        # the language wrote" reads this rather than re-deriving the two
        # collections; `compact` because a rule's description is optional
        # (behavior.bluebook's Rule) and an unnamed one quotes nothing.
        def guard_descriptions = (@givens + @ensures).map(&:description).compact
      end

      # A MUTATION'S OWN READINGS. Included (not extended) — Mutation is
      # a Struct, so these are instance methods.
      module Mutation
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
    end
  end
end
