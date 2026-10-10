module RuboCop
  module Cop
    module Hecks
      # Flags one method that reads the same receiver by `[:name]` and by `["name"]`.
      #
      # A hash is symbol-keyed under one persistence adapter and string-keyed under another, so a
      # method that reaches for both is guessing which one it was handed. Read it through
      # `Hecks::Naming.fetch_key` (or normalize the keys once at the boundary) so the guess is made
      # in one place that honors a stored `false`.
      #
      # @example
      #   settings.key?(:era) ? settings[:era] : settings["era"]  # bad
      #   Naming.fetch_key(settings, :era)                        # good
      class SymbolStringKeyMix < Base
        MSG = "`%<receiver>s[:%<name>s]` and `%<receiver>s[\"%<name>s\"]` are both read here, so this " \
              "method guesses whether the hash is symbol- or string-keyed. Read it through one " \
              "helper, or normalize the keys once at the boundary.".freeze

        # @!method keyed_read(node)
        def_node_matcher :keyed_read, "(send $_receiver :[] ({sym str} $_name))"

        # Flags the string-keyed read when the same name is also read by symbol.
        #
        # @param node [RuboCop::AST::DefNode] the method being visited
        # @return [void]
        def on_def(node)
          reads = node.each_descendant(:send).filter_map { |send| read_of(send) }
          reads.group_by { |read| read.values_at(:receiver, :name) }.each_value do |group|
            report(group) if group.map { |read| read[:type] }.uniq.size > 1
          end
        end
        alias on_defs on_def

        private

        def read_of(send)
          receiver, name = keyed_read(send)
          return unless receiver

          { receiver: receiver.source, name: name.to_s, type: send.first_argument.type, node: send }
        end

        def report(group)
          string_read = group.find { |read| read[:type] == :str }
          message = format(MSG, receiver: string_read[:receiver], name: string_read[:name])
          add_offense(string_read[:node], message: message)
        end
      end
    end
  end
end
