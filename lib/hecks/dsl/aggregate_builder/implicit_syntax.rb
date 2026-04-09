# Hecks::DSL::AggregateBuilder::ImplicitSyntax
#
# method_missing-based implicit DSL support extracted from AggregateBuilder.
# Enables shorthand syntax like `title String` and `Topping do ... end`.
#
module Hecks
  module DSL
    class AggregateBuilder
      module ImplicitSyntax
        def method_missing(name, *args, **kwargs, &block)
          name_s = name.to_s
          if Hecks::DSL::TypeName.match?(name_s) && block_given?
            value_object(name_s, &block)
          elsif block_given?
            command(infer_command_name(name_s), &block)
          elsif type_argument?(args.first)
            attribute(name, args.first, **kwargs)
          else
            super
          end
        end

        def respond_to_missing?(name, include_private = false)
          true
        end


        private

        # Detects whether an argument looks like a type descriptor:
        # - A Class (String, Integer)
        # - A PascalCase string ("Topping")
        # - A hash with :list or :reference key
        def type_argument?(arg)
          return false unless arg
          arg.is_a?(Class) ||
            Hecks::DSL::TypeName.match?(arg) ||
            (arg.respond_to?(:key?) && arg.key?(:list))
        end

        def infer_command_name(snake)
          parts = snake.split("_")
          parts.size == 1 ? parts.first.capitalize + @name : parts.map(&:capitalize).join
        end
      end
    end
  end
end
