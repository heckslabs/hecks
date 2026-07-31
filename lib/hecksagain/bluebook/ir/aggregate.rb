module Hecksagain
  module Bluebook
    module IR
      class Aggregate

        # The BLUEBOOK's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        def hecks_name = @name
        attr_reader :name, :description, :attributes, :value_objects, :commands,
                    :identified_by, :identity_path, :lifecycle, :entities, :queries, :policies, :reference_targets

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
          # The PATH "number.value" says which field carries the identity ;
          # `identified_by` stays the HEAD attribute, which is what every reader
          # that looks up or coerces an attribute actually wants.
          @identity_path = identified_by.to_s
          @identified_by = @identity_path.split(".").first.to_sym
          @lifecycle     = lifecycle
          @reference_targets = reference_targets

          # Indexed once here, since @attributes/@value_objects/@commands/@queries
          # are final by the time an Aggregate exists — every dispatch asks these
          # finders by name, and a linear scan repeated on every call was doing
          # work the declared shape had already settled at boot.
          @attributes_by_name    = @attributes.to_h { |a| [a.name, a] }
          @value_objects_by_name = @value_objects.to_h { |shape| [shape.hecks_name, shape] }
          @commands_by_name      = @commands.to_h { |verb| [verb.hecks_name, verb] }
          @queries_by_name       = @queries.to_h { |ask| [ask.hecks_name, ask] }
        end

        def attribute(named)    = @attributes_by_name[named.to_sym]
        # A value object is a CLASS now, so `name` is Ruby's answer (the constant
        # path) and the declared name is `hecks_name`. This finder is on its way
        # out — once an attribute's type IS the class there is nothing to find —
        # but every consumer still asks by type string, so it stays until they
        # stop.
        def value_object(named) = @value_objects_by_name[named.to_s]
        def command(named)      = @commands_by_name[named.to_s]
        # An aggregate answers for its own asks the way it answers for its verbs.
        # An entity has had this finder all along and a head had not, so
        # `QueryInterpreter` hand-rolled the same search — asymmetry, not design.
        def query(named)        = @queries_by_name[named.to_s]

        def storage_name = Naming.snake(@name)

        def to_h
          {
            name:          @name,
            description:   @description,
            identified_by: @identity_path.to_sym,
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
