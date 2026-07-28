module Hecksagain
  module Bluebook
    module IR
      class Attribute
        attr_reader :name, :type, :default

        def initialize(name:, type:, list: false, default: nil)
          @name    = name.to_sym
          @type    = type.to_s
          @list    = list
          @default = default
        end

        def list?   = @list
        def scalar? = !@list

        PRIMITIVES = %w[String Integer Float TrueClass FalseClass].freeze
        def primitive? = PRIMITIVES.include?(@type)

        def to_h
          { name: @name, type: @type, list: @list, default: @default }
        end
      end
    end
  end
end
