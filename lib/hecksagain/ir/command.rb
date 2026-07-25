# Command — one thing a role can say to an aggregate, and what happens when
# they say it. The whole behaviour is DECLARED, never scripted:
#
#   given     — a guard ; all must hold or the command is refused
#   then_set  — a mutation ; `to:` replaces, `append:` pushes onto a list
#   emits     — the event announced after the mutations land
#
# `reference_to` marks a command as acting on an EXISTING instance (loaded by
# id) rather than minting a new one. That single flag is what separates a
# create from an update — there is no separate create keyword.
#
#   Command.new(name: "AddTopping", references: "Pizza", mutations: [...])
module Hecksagain
  module IR
    # description — the sentence from the bluebook ("max 10 toppings")
    # predicate   — block, instance_eval'd against the aggregate instance
    Given = Struct.new(:description, :predicate, keyword_init: true)

    # target — attribute being written
    # op     — :set (replace) or :append (push onto a list)
    # source — for :set, the command attribute name ; for :append, a hash of
    #          { vo_field => command_attribute } used to build the element
    Mutation = Struct.new(:target, :op, :source, keyword_init: true)

    class Command
      attr_reader :name, :role, :goal, :attributes, :givens, :mutations, :emits, :references

      def initialize(name:, role: nil, goal: nil, attributes: [], givens: [],
                     mutations: [], emits: [], references: nil)
        @name       = name.to_s
        @role       = role
        @goal       = goal
        @attributes = attributes
        @givens     = givens
        @mutations  = mutations
        @emits      = emits
        @references = references&.to_s
      end

      # A command that references its own aggregate acts on an existing
      # instance ; one that does not mints a fresh one.
      def creates? = @references.nil?

      def attribute(named) = @attributes.find { |a| a.name == named.to_sym }

      def to_h
        {
          name:       @name,
          role:       @role,
          goal:       @goal,
          references: @references,
          attributes: @attributes.map(&:to_h),
          givens:     @givens.map(&:description),
          mutations:  @mutations.map(&:to_h),
          emits:      @emits
        }
      end
    end
  end
end
