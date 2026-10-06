module RuboCop
  module Cop
    module Hecks
      # Flags `holder[a] || holder[b]`: the same receiver looked up by two keys, falling back
      # to the second when the first is falsy.
      #
      # `||` cannot tell a stored `false` from a missing key, so a real `false` at `holder[a]` is
      # discarded. Different receivers (`a[k] || b[k]`) and plain defaults are left alone.
      #
      # @example
      #   hash[:active] || hash["active"]                      # bad
      #   hash.key?(:active) ? hash[:active] : hash["active"]  # good
      class FallbackHashLookup < Base
        MSG = "`%<receiver>s[...] || %<receiver>s[...]` falls back to the second lookup " \
              "whenever the first is falsy — but `||` cannot tell a genuinely stored `false` " \
              "apart from a missing key, so a real `false` at `%<receiver>s[%<lhs_key>s]` is " \
              "silently discarded in favor of `%<receiver>s[%<rhs_key>s]` instead of being " \
              "returned. Use `%<receiver>s.key?(%<lhs_key>s) ? %<receiver>s[%<lhs_key>s] : " \
              "%<receiver>s[%<rhs_key>s]`, or a shared digger (see `key?` in " \
              "`Hecks::QuerySpecification::FieldPath#read`), instead.".freeze

        # @!method bracket_lookup(node)
        def_node_matcher :bracket_lookup, "(send $_receiver :[] $_key)"

        # Flags an `a[k] || a[k2]` double bracket-lookup on the same receiver.
        #
        # @param node [RuboCop::AST::OrNode] the `||` node being visited
        # @return [void]
        def on_or(node)
          lhs_receiver, lhs_key = bracket_lookup(node.lhs)
          return unless lhs_receiver

          rhs_receiver, rhs_key = bracket_lookup(node.rhs)
          return unless rhs_receiver

          # **The structural equality check** — `==` on an AST node (from the
          # `ast` gem `Node` this compiles down to) compares `type` and
          # `children` recursively and ignores source location, so
          # `hash[a] || hash[b]` matches even though the two `hash`
          # sub-nodes are two distinct node objects parsed from two
          # different source ranges. A different receiver on each side
          # (`a[k] || b[k]`) fails this check and is correctly left alone.
          return unless lhs_receiver == rhs_receiver

          add_offense(node, message: offense_message(lhs_receiver, lhs_key, rhs_key))
        end

        private

        def offense_message(receiver, lhs_key, rhs_key)
          format(MSG, receiver: receiver.source, lhs_key: lhs_key.source, rhs_key: rhs_key.source)
        end
      end
    end
  end
end

# AST `==` ignores source location, so two parses of the same receiver compare equal.
