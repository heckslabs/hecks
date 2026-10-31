module RuboCop
  module Cop
    module Hecks
      # Flags a quoted event or query name where its constant belongs: `starts_on "Message.Sent"`,
      # `on "Sent"`, `trigger`, `for_each`, or a transition key `"Churn" => "churned"`. The constant
      # fails when the bluebook loads; the string fails only at run time.
      #
      # Quoted state names stay quoted: a transition target and a `from:` name a state.
      #
      # @example
      #   starts_on "Message.Sent"                          # bad
      #   starts_on Message::Sent                           # good
      #   transition "Churn" => "churned", from: "active"   # bad: the key names a command
      #   transition Churn => "churned", from: "active"     # good
      class BareEventAndQueryNames < Base
        MSG = "`\"%<name>s\"` names an event or query by its string. Name it by its constant, " \
              "`%<const>s`, so a misspelling fails at load.".freeze

        STRING_NAMED_CALLS = %i[starts_on on trigger for_each].freeze
        # `Message.Sent` (Aggregate.Name) or a bare `Sent`: a capitalised event or query name.
        EVENT_NAME = /\A(?:[A-Z]\w*\.)?[A-Z]\w*\z/

        # Flags a quoted event or query name passed to a call that takes one, or as a key.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless node.receiver.nil?

          if STRING_NAMED_CALLS.include?(node.method_name)
            flag_string_arguments(node)
          elsif node.method_name == :transition
            flag_transition_keys(node)
          end
        end

        private

        def flag_string_arguments(node)
          node.arguments.each { |argument| flag_name(argument) if argument.str_type? }
        end

        def flag_transition_keys(node)
          node.arguments.select(&:hash_type?).each do |hash|
            hash.pairs.each { |pair| flag_name(pair.key) if pair.key.str_type? }
          end
        end

        def flag_name(node)
          name = node.value
          return unless EVENT_NAME.match?(name)

          add_offense(node, message: format(MSG, name: name, const: name.split(".").join("::")))
        end
      end
    end
  end
end
