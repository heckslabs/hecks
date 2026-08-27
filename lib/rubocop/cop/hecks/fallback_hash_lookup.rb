module RuboCop
  module Cop
    module Hecks
      # FLAGS THE EXACT SHAPE behind 8+ real bugs already fixed one at a
      # time across this codebase (Tiers 1-5): `holder[a] || holder[b]` —
      # the SAME receiver looked up by two different keys, falling back to
      # the second lookup whenever the first is falsy. `||` cannot tell a
      # genuinely STORED `false` from a MISSING key — both are falsy in
      # Ruby — so a real `false` sitting at `holder[a]` is silently
      # discarded and `holder[b]` (usually absent, so `nil`) is returned
      # instead. Every one of those 8+ instances was the identical
      # AST shape with a different pair of keys (most commonly
      # `h[k.to_sym] || h[k]`, reading a value that could arrive keyed
      # either by symbol or by string off the wire).
      #
      # THE FIX THIS CODEBASE ALREADY CONVERGED ON — see
      # `lib/hecks/query_specification/field_path.rb#read`, the shared
      # digger this whole bug class got consolidated behind: check
      # `key?` FIRST, never fall back through `||`.
      #
      #   sym = segment.to_sym
      #   return current.key?(sym) ? current[sym] : current[segment]
      #
      # That method's own comment says it plainly: "`key?` first, never
      # `||`, because `||` falls through a genuinely-stored `false` to
      # the OTHER spelling (usually absent) and returns `nil` instead."
      # This cop exists so the NEXT `holder[a] || holder[b]` gets caught
      # mechanically, before it becomes bug #9, rather than found by
      # hand again in a future audit.
      #
      # SCOPED TO THE `[]`/`[]` SHAPE ONLY, deliberately — a receiver
      # method-call is compared by AST structure (`==`, which ignores
      # source location), so `hash[a] || hash[b]` is flagged whether
      # `hash` is a local variable, a method call, or a constant, but
      # `a[k] || b[k]` (DIFFERENT receivers) and `value || default`
      # (an ordinary default, not a second lookup at all) are both left
      # alone — neither one can silently drop a stored `false` the way
      # a same-receiver double-lookup can.
      #
      # @example
      #   # bad — a stored `false` at hash[:active] is discarded
      #   hash[:active] || hash["active"]
      #
      #   # good
      #   hash.key?(:active) ? hash[:active] : hash["active"]
      #
      #   # good — or the shared digger this codebase already has
      #   Hecks::QuerySpecification::FieldPath.dig(hash, "active")
      class FallbackHashLookup < Base
        MSG = "`%<receiver>s[...] || %<receiver>s[...]` falls back to the second lookup " \
              "whenever the first is falsy — but `||` cannot tell a genuinely stored `false` " \
              "apart from a missing key, so a real `false` at `%<receiver>s[%<lhs_key>s]` is " \
              "silently discarded in favor of `%<receiver>s[%<rhs_key>s]` instead of being " \
              "returned. Use `%<receiver>s.key?(%<lhs_key>s) ? %<receiver>s[%<lhs_key>s] : " \
              "%<receiver>s[%<rhs_key>s]`, or a shared digger (see `key?` in " \
              "`Hecks::QuerySpecification::FieldPath#read`), instead."

        # @!method bracket_lookup(node)
        def_node_matcher :bracket_lookup, "(send $_receiver :[] $_key)"

        def on_or(node)
          lhs_receiver, lhs_key = bracket_lookup(node.lhs)
          return unless lhs_receiver

          rhs_receiver, rhs_key = bracket_lookup(node.rhs)
          return unless rhs_receiver

          # THE STRUCTURAL EQUALITY CHECK — `==` on an AST node (from the
          # `ast` gem `Node` this compiles down to) compares `type` and
          # `children` recursively and ignores source location, so
          # `hash[a] || hash[b]` matches even though the two `hash`
          # sub-nodes are two distinct node OBJECTS parsed from two
          # different source ranges. A different receiver on each side
          # (`a[k] || b[k]`) fails this check and is correctly left alone.
          return unless lhs_receiver == rhs_receiver

          add_offense(
            node,
            message: format(
              MSG,
              receiver: lhs_receiver.source,
              lhs_key:  lhs_key.source,
              rhs_key:  rhs_key.source
            )
          )
        end
      end
    end
  end
end
