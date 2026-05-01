module Hecks
  module DSL

    # Hecks::DSL::Describable
    #
    # Mixin that adds a `description` keyword to any DSL builder. When called
    # with an argument it stores the text; when called without it returns the
    # stored value. Builders that include this module pass @description through
    # to their IR node's `description:` keyword.
    #
    #   class MyBuilder
    #     include Describable
    #
    #     def build
    #       SomeIRNode.new(name: @name, description: @description)
    #     end
    #   end
    #
    #   builder = MyBuilder.new("Foo")
    #   builder.description "A short explanation"
    #   builder.description  # => "A short explanation"
    #
    module Describable
      def description(text = nil)
        if text
          @description = text
        else
          @description
        end
      end
    end
  end
end
