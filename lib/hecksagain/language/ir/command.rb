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
  module Language
    module IR
      # description — the sentence from the bluebook ("max 10 toppings")
      # canonical   — the expression as text ("toppings.size < 10"), extracted
      #               from the real Ruby by Prism. THIS is what runtimes
      #               evaluate ; it is the only form that crosses a language
      #               boundary.
      # predicate   — the original block, kept for source-of-truth reference and
      #               for the agreement test that proves the text still means
      #               what the Ruby meant. Never the evaluation path.
      Given = Struct.new(:description, :canonical, :predicate, keyword_init: true)

      # target — attribute being written
      # op     — :set (replace) or :append (push onto a list)
      # source — for :set, a Symbol naming a command attribute OR a literal ;
      #          for :append, a hash of { vo_field => command_attribute }
      #
      # In Ruby the Symbol/String distinction carries the meaning : `to: :status`
      # reads an argument, `to: "sold"` is a literal. JSON has no symbols, so the
      # export must say WHICH it is — otherwise a runtime reading the IR sees two
      # identical strings and has to guess, and it will guess wrong exactly when
      # an argument happens to share a name with a plausible literal.
      Mutation = Struct.new(:target, :op, :source, keyword_init: true) do
        def to_h
          base = { target: target, op: op }
          return base.merge(fields: source) if op == :append

          base.merge(source: classified_source)
        end

        def classified_source
          if source.is_a?(Symbol)
            { kind: "argument", name: source.to_s }
          else
            { kind: "literal", value: source }
          end
        end
      end

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
            givens:     @givens.map { |g| { description: g.description, canonical: g.canonical } },
            mutations:  @mutations.map(&:to_h),
            emits:      @emits
          }
        end
      end
    end
  end
end
