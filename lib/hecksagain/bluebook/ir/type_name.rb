module Hecksagain
  module Bluebook
    module IR
      class TypeName
        attr_reader :name

        def initialize(name)
          @name = name.to_s
        end

        def to_s = @name
        def to_sym = @name.to_sym
        def inspect = "#<TypeName #{@name}>"
        def ==(other) = other.to_s == @name
        alias eql? ==
        def hash = @name.hash
      end
    end
  end
end
