module Hecksagain
  module Bluebook
    module DSL
      class CommandBuilder
        include AttributeCollector

        def initialize(name, owner: nil)
          @name      = name
          @owner     = owner
          @givens    = []
          @ensures   = []
          @mutations = []
          @emits     = []
        end

        # A command carries ONE responsibility role — the language never
        # declared an OR between two roles, so a second `role` call would
        # otherwise silently win while the first still looked declared,
        # exactly the failure mode `reference_to`'s own duplicate guard
        # (below) already exists to prevent for a command's root.
        def role(value)
          raise Malformed,
                "#{@name} declares role twice — a command carries ONE " \
                "responsibility; the second would silently win and the " \
                "first would still look declared" if @role

          @role = value
        end

        def goal(value) = @goal = value

        # See AggregateBuilder#provenance's own comment — identical shape,
        # one level down.
        def provenance(from:) = @provenance = from

        # `optional:` rides here as well as on a plain attribute : `as:` makes a
        # reference into a NAMED ARGUMENT, and a named argument is exactly the kind
        # of fact that may or may not be given. The meta-domain's Verb.Declare
        # points at the Entity a command belongs to — and most commands belong to no
        # entity at all.
        def reference_to(type, as: nil, optional: false)
          demodulised = Naming.demodulise(type)
          # moved to the language: given "a command names what it acts on", on Verb.ActsOn

          # `as:` MEANS "a named attribute", not "the root I act on" — so a command
          # can point at another instance of its OWN kind. Without this,
          # `reference_to Aggregate, as: :points_at` on a command owned by Aggregate
          # read as a second self-reference and was refused as naming two roots,
          # which is how the meta-domain's own Aggregate.Reference could not say the
          # one thing it exists to say. Transfer has said
          # `reference_to Account, as: :source` for as long as banking has existed;
          # this is the same sentence when the target happens to be the owner.
          return cross_reference(demodulised, as, optional) if as || demodulised.to_s != @owner.to_s

          if @references
            raise Malformed,
                  "#{@name} references #{@owner} twice — a command acts on ONE " \
                  "root ; the second would silently win and the first would " \
                  "still look declared"
          end

          @references = demodulised
        end

        private

        def cross_reference(target, as, optional = false)
          attribute(as || :"#{Naming.snake(target)}_id", IR::Reference.new(target), optional: optional)
        end

        public

        def given(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # moved to the language: given "a rule says what it means", on Verb.Rule

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s given #{description.inspect} did not survive " \
                  "extraction — its source could not be read, so no other " \
                  "runtime could ever evaluate it"
          end

          @givens << IR::Given.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        # The POSTCONDITION — a given for the far side of the mutations,
        # evaluated against the settled record with `old` naming the state
        # as it stood before them: `ensures("...") { old.balance.cents ==
        # balance.cents + amount.cents }`. Same extraction, same Rule
        # shape, same refusal form; EnsuresNotMet instead of GivenNotMet.
        def ensures(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s ensures #{description.inspect} did not survive " \
                  "extraction — a postcondition is carried as text, and this " \
                  "one has none"
          end

          @ensures << IR::Given.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        # `sets` is the word; `then_set` is the spelling every existing
        # bluebook was written under (Syntax::Keyword carries the rename as
        # `was:`), and it stays answered here forever — a renamed word's old
        # era keeps booting, which is the whole point of the rename column.
        def then_set(target, to: nil, append: nil, increment: nil, decrement: nil)
          # moved to the language: given "a mutation names a target", on Verb.Change

          named = { set: to, append: append, increment: increment, decrement: decrement }
                  .reject { |_, source| source.nil? }

          if named.empty?
            raise Malformed,
                  "#{@name}'s then_set :#{target} names no operation — " \
                  "give it to:, append:, increment:, or decrement:"
          end

          if named.size > 1
            raise Malformed,
                  "#{@name}'s then_set :#{target} tries to #{named.keys.join(' and ')} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << IR::Mutation.new(target: target.to_sym, op: op, source: source)
        end
        alias_method :sets, :then_set

        # No raise here. "an event is named" is declared in the language itself —
        # language/bluebook/behavior.bluebook, on Command.Announce — and MetaValidator is what
        # enforces it. This is the first rule to move ACROSS rather than be
        # duplicated : delete the declaration and an unnamed event is accepted,
        # which is what makes the meta-domain load-bearing rather than decorative.
        def emits(event_name)
          @emits << event_name.to_s
        end

        def build
          IR::Command.declare(
            name:       @name,
            role:       @role,
            goal:       @goal,
            attributes: attributes,
            givens:     @givens,
            ensures:    @ensures,
            mutations:  @mutations,
            emits:      @emits,
            references: @references,
            provenance: @provenance
          )
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
