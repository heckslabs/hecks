require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What a command does**. Extended, not included — a command is a
      # class, one per declared verb.
      module Command
        include Indexed

        # Indexed once — attributes are final once absorbed, and every
        # dispatch asks this finder by name.
        #
        # @return [Class] self — the command class, once its attributes are
        #   indexed
        def settle
          index_attributes(@attributes)
          self
        end

        # The construct this verb acts upon — the construct itself, not its name.
        #
        # A verb declared on an entity always acts on that piece. It never
        # self-references, because an element is addressed through its parent —
        # which means `creates?` answers true for every one of them, and reading
        # `acts_on` off `creates?` alone would report that `LedgerEntry.Amend`
        # brings a ledger entry into being. Three of banking's commands were
        # about to say exactly that, and nothing would have contradicted them.
        #
        # On an aggregate, a creating command acts on no existing root, so nil is
        # the truth: there is nothing there yet.
        #
        # @return [Class, Bluebook::Aggregate, nil] the entity class (a
        #   `Bluebook::Entity` subclass) this verb acts on when declared on an
        #   entity, the aggregate instance when declared on an aggregate and
        #   non-creating, or `nil` for a creating command
        def acts_on
          # Fully qualified, and it has to be: inside `module Behaviour`
          # the bare name `Entity` resolves to Behaviour::Entity — this
          # module's sibling — not to the construct. Comparing a Class to
          # a Module answers nil, so the guard silently fell through and
          # every entity verb reported acting on nothing.
          return hecks_owner if hecks_owner.is_a?(Class) && hecks_owner < Bluebook::Entity

          creates? ? nil : hecks_owner
        end

        # Whether this command creates a new root rather than acting on one.
        #
        # @return [Boolean] whether this command creates a new root — true when
        #   it declares no `reference_to` back to its own owner
        def creates? = @references.nil?

        # Every reason this verb can refuse on a rule — the descriptions of
        # its givens and its ensures, the exact text the runtime quotes
        # after "refused — " when a guard is not met (see
        # command_rules/admissibility.rb's GivenNotMet/EnsuresNotMet). A
        # property that asks "did the runtime only ever refuse for a rule
        # the language wrote" reads this rather than re-deriving the two
        # collections; `compact` because a rule's description is optional
        # (behavior.bluebook's Rule) and an unnamed one quotes nothing.
        #
        # @return [Array<String>] every named given's and ensure's own
        #   description text, skipping unnamed rules
        def guard_descriptions = (@givens + @ensures).map(&:description).compact

        # The argument name that addresses an instance of `aggregate_name`
        # for this command — the one fact `PolicyInterpreter`'s own
        # `for_each` fan-out needs and, until this reading existed, had
        # to guess at (see git blame: `Behaviour::Policy
        # #fan_out_reference_key`, which hardcoded `<aggregate>_id`
        # unconditionally and refused every dispatch to a self-
        # addressing command as a result — `Account.Freeze`, addressed
        # by `number`/`account`, not `account_id`).
        #
        # Two shapes, the same two `CommandBuilder#reference_to` already
        # tells apart at declare time (command_builder.rb's own comment
        # on `cross_reference` — "`as:` means a named attribute... a
        # command can point at another instance of its own kind"):
        #
        #   self-addressing — `references == aggregate_name` (this verb
        #   is declared on the very aggregate it acts on, `reference_to
        #   Account` on a command Account itself owns). No attribute was
        #   minted for it at all; the same bare key
        #   `CommandInterpreter::ArgumentGate#reference_key` already
        #   accepts as "addressing, not describing" is reused here
        #   rather than re-derived — one door, not two.
        #
        #   cross-referencing — a real, declared reference-typed
        #   attribute whose own target is `aggregate_name` (`customer_id`
        #   on `Account.Open`, or whatever `as:` named it). Its name is
        #   the key, exactly as declared — never re-derived from the
        #   target's name, because an `as:` reference's name and its
        #   target's snake case can legitimately differ (`Transfer`'s own
        #   `source`/`destination`, both `Reference<Account>`).
        #
        # `nil` when neither shape matches — a creating command (nothing
        # to address yet) or one that simply never references this
        # aggregate at all. A caller minting a fan-out dispatch is
        # expected to treat `nil` as "this command cannot be addressed by
        # a row of this aggregate," not to fall back on a guess.
        #
        # @param aggregate_name [String, Symbol] the aggregate a fan-out dispatch is
        #   addressing an instance of
        # @return [String, nil] the argument name that addresses it, or nil if this command
        #   cannot be addressed by a row of that aggregate
        def addressing_key_for(aggregate_name)
          return Naming.reference_key(aggregate_name) if references.to_s == aggregate_name.to_s

          attributes.find { |attribute| attribute.reference? && attribute.type.target_name.to_s == aggregate_name.to_s }
                    &.name
        end
      end

      # **A mutation's own readings**. Included (not extended) — Mutation is
      # a Struct, so these are instance methods.
      module Mutation
        # An append binds several fields at once, each from either a command
        # argument (a Symbol) or a literal. Spelled through `Literal.render`,
        # the same self-describing form a where-clause's own value already
        # uses, rather than a bare Symbol paired with an inspected literal —
        # see Hecks::Literal.
        #
        # @return [Hash{Symbol => String}] the append's field bindings, each
        #   value rendered through `Literal.render`
        def appended_fields = source.transform_values { |value| Literal.render(value) }

        # Classifies this mutation's source for the wire, the counterpart
        # `Assembly::Marks#classified` reads back.
        #
        # @return [Hash{Symbol => Object}] `{kind: "argument", name:}` for a
        #   command argument, `{kind: "state", name:}` for a state
        #   self-reference, or `{kind: "literal", value:}` for a literal value
        def classified_source
          if source.is_a?(Symbol)
            { kind: "argument", name: source.to_s }
          elsif source.is_a?(StateRef)
            { kind: "state", name: source.name.to_s }
          else
            { kind: "literal", value: source }
          end
        end
      end
    end
  end
end
