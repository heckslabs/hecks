module Hecksagain
  module Bluebook
    module IR
      class Aggregate
        attr_reader :name, :description, :attributes, :value_objects, :commands,
                    :identified_by, :lifecycle, :entities, :queries, :policies, :reference_targets

        attr_accessor :ruby_class

        def initialize(name:, description: nil, attributes: [], value_objects: [],
                       commands: [], identified_by: :id, lifecycle: nil,
                       entities: [], queries: [], policies: [], reference_targets: [])
          @entities      = entities
          @queries       = queries
          @policies      = policies
          @name          = name.to_s
          @description   = description
          @attributes    = attributes
          @value_objects = value_objects
          @commands      = commands
          @identified_by = identified_by.to_sym
          @lifecycle     = lifecycle
          @reference_targets = reference_targets
        end

        def attribute(named)    = @attributes.find { |a| a.name == named.to_sym }
        # A value object is a CLASS now, so `name` is Ruby's answer (the constant
        # path) and the declared name is `hecks_name`. This finder is on its way
        # out — once an attribute's type IS the class there is nothing to find —
        # but every consumer still asks by type string, so it stays until they
        # stop.
        def value_object(named) = @value_objects.find { |shape| shape.hecks_name == named.to_s }
        def command(named)      = @commands.find { |c| c.name == named.to_s }

        def storage_name = Naming.snake(@name)

        def to_h
          {
            name:          @name,
            description:   @description,
            identified_by: @identified_by,
            attributes:    @attributes.map(&:to_h),
            value_objects: @value_objects.map(&:to_h),
            commands:      @commands.map(&:to_h),
            lifecycle:     @lifecycle&.to_h,
            entities:      @entities.map(&:to_h),
            queries:       @queries.map(&:to_h)
          }
        end
      end
    end
  end
end
