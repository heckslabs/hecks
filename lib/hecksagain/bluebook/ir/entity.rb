module Hecksagain
  module Bluebook
    module IR
      class Entity
        attr_reader :name, :description, :identified_by, :attributes,
                    :commands, :queries, :lifecycle

        def initialize(name:, description: nil, identified_by: nil, attributes: [],
                       commands: [], queries: [], lifecycle: nil)
          @name          = name.to_s
          @description   = description
          @identified_by = identified_by
          @attributes    = attributes
          @commands      = commands
          @queries       = queries
          @lifecycle     = lifecycle
        end

        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }
        def command(named)   = @commands.find { |verb| verb.hecks_name == named.to_s }
        def query(named)     = @queries.find { |q| q.name == named.to_s }

        def to_h
          {
            name:          @name,
            description:   @description,
            identified_by: @identified_by&.to_s,
            attributes:    @attributes.map(&:to_h),
            commands:      @commands.map(&:to_h),
            queries:       @queries.map(&:to_h),
            lifecycle:     @lifecycle&.to_h
          }
        end
      end
    end
  end
end
