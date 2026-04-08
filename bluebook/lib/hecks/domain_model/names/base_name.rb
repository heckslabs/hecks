# Hecks::BluebookModel::Names::BaseName
#
# Base class for name value objects. Inherits from String so it works
# transparently everywhere strings are used — hash keys, comparisons,
# interpolation, regex. Subclasses add semantic meaning without
# changing behavior.
#
#   class MyName < BaseName; end
#   name = MyName.wrap("Foo")
#   name == "Foo"            # => true
#   { name => 1 }["Foo"]    # => 1
#   "Hello #{name}"          # => "Hello Foo"
#
module Hecks
  module BluebookModel
    module Names
      class BaseName < String
        def self.wrap(value)
          value.is_a?(self) ? value : new(value.to_s)
        end

        def initialize(value)
          super(value)
          freeze
        end

        # Use the standard String inspect so generated code gets "CreatePizza"
        # not EventName("CreatePizza"). Use .class.name for debugging.

      end
    end
  end
end
