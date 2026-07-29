module Hecksagain
  module Bluebook
    module DSL
      class CommandBuilder
        include AttributeCollector

        def initialize(name, owner: nil)
          @name      = name
          @owner     = owner
          @givens    = []
          @mutations = []
          @emits     = []
        end

        def role(value) = @role = value
        def goal(value) = @goal = value

        def reference_to(type, as: nil)
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
          return cross_reference(demodulised, as) if as || demodulised.to_s != @owner.to_s

          if @references
            raise Malformed,
                  "#{@name} references #{@owner} twice — a command acts on ONE " \
                  "root ; the second would silently win and the first would " \
                  "still look declared"
          end

          @references = demodulised
        end

        private

        def cross_reference(target, as)
          attribute(as || :"#{Naming.snake(target)}_id", "Reference<#{target}>")
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

        # No raise here. "an event is named" is declared in the language itself —
        # grammar/bluebook.bluebook, on Verb.Announce — and MetaValidator is what
        # enforces it. This is the first rule to move ACROSS rather than be
        # duplicated : delete the declaration and an unnamed event is accepted,
        # which is what makes the meta-domain load-bearing rather than decorative.
        def emits(event_name)
          @emits << event_name.to_s
        end

        def build
          IR::Command.new(
            name:       @name,
            role:       @role,
            goal:       @goal,
            attributes: attributes,
            givens:     @givens,
            mutations:  @mutations,
            emits:      @emits,
            references: @references
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
