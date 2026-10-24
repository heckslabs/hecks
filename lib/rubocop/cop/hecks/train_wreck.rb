module RuboCop
  module Cop
    module Hecks
      # Flags a call that reaches through one object into another: `runtime.registry.bluebooks`.
      #
      # Each bare reader in the chain steps into an object the caller was not handed, so the caller
      # now knows how that object is built. Ask the first object instead, with a method that answers
      # the question (`runtime.bluebooks`). Conversions and collection calls (`to_s`, `map`)
      # are not steps, so a chain of them is left to Hecks/UnnamedPipeline.
      #
      # @example
      #   runtime.registry.bluebooks          # bad
      #   runtime.bluebooks                   # good
      #   error.class.name                    # good: `class` is not a step into a collaborator
      class TrainWreck < Base
        MSG = "`%<chain>s` reaches through `%<through>s` into an object it was not handed. Ask `%<root>s` " \
              "for it with a method named for what you want.".freeze

        # Calls that convert, query or iterate a value rather than step into a collaborator.
        PIPELINE_METHODS = %i[
          to_s to_sym to_str to_a to_h to_i to_f to_r to_proc to_json inspect freeze dup class
          first last keys values size count length strip chomp lstrip rstrip downcase upcase capitalize
          lines chars bytes sort uniq compact flatten reverse each each_value each_key each_line lazy
          with_index each_with_index reverse_each tally sum min max now utc iso8601 source value new
        ].freeze

        # Flags the outermost call of a chain whose leading readers step past the first object.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return if chained_further?(node)

          root, reaches = leading_reaches(node)
          return if reaches.size <= max_reaches

          add_offense(reaches.last, message: message_for(root, reaches))
        end
        alias on_csend on_send

        private

        def max_reaches = cop_config.fetch("MaxReaches", 1)

        def chained_further?(node)
          node.parent&.call_type? && node.parent.receiver.equal?(node)
        end

        def leading_reaches(node)
          calls = []
          calls.unshift(node) && (node = node.receiver) while node&.call_type? && node.receiver
          [node, calls.take_while { |call| reach?(call) }]
        end

        def reach?(call)
          return false if call.arguments? || call.block_literal? || call.operator_method?

          name = call.method_name
          !(PIPELINE_METHODS.include?(name) || name.end_with?("?", "!", "="))
        end

        def message_for(root, reaches)
          format(MSG, chain: reaches.last.source, through: reaches[0..-2].map(&:method_name).join("."),
                      root: root&.source || "self")
        end
      end
    end
  end
end
