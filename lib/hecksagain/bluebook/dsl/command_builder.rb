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
          raise Malformed, "#{@name}.reference_to names nothing" if demodulised.to_s.empty?

          return cross_reference(demodulised, as) unless demodulised.to_s == @owner.to_s

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

          raise Malformed, "#{@name} has a given with no description" if description.to_s.empty?

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
          raise Malformed, "#{@name} has a then_set with no target" if target.to_s.empty?

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

        def emits(event_name)
          raise Malformed, "#{@name} emits an unnamed event" if event_name.to_s.empty?

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
