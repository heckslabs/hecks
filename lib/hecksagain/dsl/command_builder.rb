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
      def reference_to(type) = @references = type.to_s

      # The block is real Ruby and stays real Ruby ; Prism reads its source so
      # the same text can be evaluated by a runtime that has no Ruby in it.
      def given(description, &predicate)
        @givens << IR::Given.new(
          description: description,
          canonical:   Expression::Extractor.canonical(predicate),
          predicate:   predicate
        )
      end

      # then_set :status,   to: :new_status              — replace
      # then_set :toppings, append: { name: :name }      — push onto a list
      def then_set(target, to: nil, append: nil)
        if append
          @mutations << IR::Mutation.new(target: target.to_sym, op: :append, source: append)
        else
          @mutations << IR::Mutation.new(target: target.to_sym, op: :set, source: to)
        end
      end

      def emits(event_name) = @emits << event_name.to_s

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
