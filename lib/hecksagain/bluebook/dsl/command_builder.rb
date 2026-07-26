# CommandBuilder — evaluates a `command "AddTopping" do ... end` block.
#
# Everything a command does is DECLARED. There is no handler body, no `def
# call` — the runtime reads givens, mutations, and emissions straight off the
# IR. That is what makes the same declaration projectable to another language.
#
#   command "AddTopping" do
#     role "Chef"
#     goal "Customize a pizza with ingredients"
#     reference_to Pizza
#     attribute :name,   String
#     attribute :amount, Integer
#     given("max 10 toppings") { toppings.size < 10 }
#     then_set :toppings, append: { name: :name, amount: :amount }
#     emits "ToppingAdded"
#   end
module Hecksagain
  module Bluebook
    module DSL
      class CommandBuilder
        include AttributeCollector

        def initialize(name)
          @name      = name
          @givens    = []
          @mutations = []
          @emits     = []
        end

        def role(value) = @role = value
        def goal(value) = @goal = value

        # Marks the command as acting on an EXISTING instance, loaded by id.
        #
        # The BARE name, always. The const shim only fires for constants that do
        # not exist, so once any domain has installed a real class called Thing,
        # a later bluebook writing `reference_to Thing` receives that CLASS and
        # stringifies to "OtherDomain::Thing" — silently referring across
        # domains. A reference names a type, not whichever class happens to have
        # claimed the constant.
        def reference_to(type)
          if @references
            raise Malformed,
                  "#{@name} references #{@references} and #{Naming.demodulise(type)} — " \
                  "a command acts on ONE root ; the second reference would " \
                  "silently win and the first would look declared"
          end

          demodulised = Naming.demodulise(type)
          raise Malformed, "#{@name}.reference_to names nothing" if demodulised.to_s.empty?

          @references = demodulised
        end

        # The block is real Ruby and stays real Ruby ; Prism reads its source so
        # the same text can be evaluated by a runtime that has no Ruby in it.
        def given(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # A rule has to SAY what it means and SURVIVE extraction. An
          # unreadable predicate is not a lenient rule — it is a rule that
          # cannot be evaluated by any target but this one, and a bluebook
          # carrying one would pass here and refuse nothing everywhere else.
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

        # then_set :status,   to: :new_status              — replace
        # then_set :toppings, append: { name: :name }      — push onto a list
        def then_set(target, to: nil, append: nil)
          raise Malformed, "#{@name} has a then_set with no target" if target.to_s.empty?

          if to.nil? && append.nil?
            raise Malformed,
                  "#{@name}'s then_set :#{target} neither sets nor appends — " \
                  "it would record a mutation that changes nothing"
          end

          if append
            @mutations << IR::Mutation.new(target: target.to_sym, op: :append, source: append)
          else
            @mutations << IR::Mutation.new(target: target.to_sym, op: :set, source: to)
          end
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

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
