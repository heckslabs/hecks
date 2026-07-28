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
