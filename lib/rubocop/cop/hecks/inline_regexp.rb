module RuboCop
  module Cop
    module Hecks
      # Flags a regular expression written inline instead of held by a named constant.
      #
      # An inline pattern says how it matches but not what it is for, and the same pattern gets
      # retyped wherever it is needed. Name it once (`IDENTIFIER = /\A[a-z][a-z0-9_]*\z/`) beside
      # the code that uses it, or in `Hecks::Naming` when several places share it. A pattern built
      # by interpolating a runtime value cannot be a constant, so it is left alone.
      #
      # @example
      #   name.match?(/\A[a-z][a-z0-9_]*\z/)        # bad
      class InlineRegexp < Base
        MSG = "Name this pattern: assign it to a constant that says what it matches, " \
              "and use the constant here.".freeze

        # Flags a regexp literal outside a constant assignment.
        #
        # @param node [RuboCop::AST::RegexpNode] the regexp being visited
        # @return [void]
        def on_regexp(node)
          return if node.interpolation? || node.each_ancestor(:casgn).any?

          add_offense(node)
        end
      end
    end
  end
end
