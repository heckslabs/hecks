module RuboCop
  module Cop
    module Hecks
      # Flags `correlates_by "Message.id"` (or `:"Message.id"`) where the bare aggregate name
      # `correlates_by Message` says the same thing. A bare name correlates by the aggregate's
      # identity, so the dotted path only repeats it.
      #
      # A dotted path into a field (`:"widget.id"`, a lowercase head) is a field path, not an
      # aggregate's identity, and is left alone.
      #
      # @example
      #   correlates_by "Message.id"    # bad
      #   correlates_by Message         # good
      #   correlates_by :"widget.id"    # good: a field path
      class CorrelatesByAggregate < Base
        MSG = "`correlates_by \"%<key>s\"` names the aggregate's id by a dotted path. A bare aggregate " \
              "name correlates by its identity, so write `correlates_by %<name>s`.".freeze

        AGGREGATE_ID = /\A([A-Z]\w*)\.id\z/

        # Flags an aggregate's id named by a dotted path when the bare aggregate name would do.
        #
        # @param node [RuboCop::AST::SendNode] the `correlates_by` call being visited
        # @return [void]
        def on_send(node)
          return unless node.receiver.nil? && node.method_name == :correlates_by

          key = node.first_argument
          return unless key && (key.str_type? || key.sym_type?)

          match = AGGREGATE_ID.match(key.value.to_s)
          return unless match

          add_offense(key, message: format(MSG, key: key.value, name: match[1]))
        end
      end
    end
  end
end
