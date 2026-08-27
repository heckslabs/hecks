module RuboCop
  module Cop
    module Hecks
      # FLAGS `hash[new] = hash.delete(old)` INSIDE A LOOP — a method that
      # both READS and WRITES the same hash across a loop's iterations,
      # in the specific rename/permutation shape this codebase has
      # already lost real data to once.
      #
      # THE BUG THIS IS THE MECHANICAL FOLLOW-UP TO (M27,
      # docs/audits/2026-08-10-main-bug-audit.md,
      # docs/audits/2026-08-11-bug-triage.md; fixed in
      # `Hecks::Ports::Persistence::Lineage#apply_renames`,
      # lib/hecks/ports/persistence/plugins/era/lineage.rb): a rename
      # rule set applied one rule at a time, `state[new_name] =
      # state.delete(old_name)` per rule, against the SAME hash it was
      # reading from — so a swap (`rename :a, to: :b` alongside `rename
      # :b, to: :a`) on `{a: 1, b: 2}` collapsed to `{a: 1}`. The first
      # rule wrote `b: 1` (clobbering the real `b: 2`) before the second
      # rule ever got a chance to read the value that was supposed to
      # move to `:a` — sequential edits stepping on each other, not the
      # simultaneous permutation a rename set actually means. The same
      # shape loses data identically for ANY chain longer than one link
      # (`a->b->c->a`), not just a two-element swap.
      #
      # THE FIX THIS COP POINTS AT — snapshot every old key's value
      # FIRST, delete all old keys, THEN write all new keys, so no
      # rename in the pass ever reads a key this same pass has already
      # written:
      #
      #   snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
      #   snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
      #   snapshot.each { |_old_name, new_name, value| state[new_name] = value }
      #
      # WHAT THIS COP DOES NOT ATTEMPT — the general checklist item is
      # broader than any AST pattern can safely automate ("any method
      # that both reads and writes the same collection across a loop"
      # covers plenty of correct code too — accumulating into a result
      # hash, memoizing into a cache). This cop stays narrow and
      # precise: only the EXACT `recv[x] = recv.delete(y)` shape, same
      # receiver both sides, inside something that iterates. A single
      # rename outside any loop is not this bug (nothing else can have
      # run first); `hash.store(...)` instead of `hash[...] =`, or
      # `hash.delete(...)` whose result is not immediately written back
      # into the SAME hash, are not this shape either and are left to
      # the broader code-review checklist item, not this cop.
      #
      # @example
      #   # bad — one rule at a time against the hash it reads from
      #   renames.each do |old_name, new_name|
      #     state[new_name] = state.delete(old_name)
      #   end
      #
      #   # good — snapshot first, then delete, then write: one permutation
      #   snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
      #   snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
      #   snapshot.each { |_old_name, new_name, value| state[new_name] = value }
      class SequentialHashRenameInLoop < Base
        MSG = "`%<recv>s[new] = %<recv>s.delete(old)` inside a loop applies one rename at a time against the " \
              "SAME hash it reads from — a swap (`{a: :b, b: :a}`) on `{a: 1, b: 2}` collapses to `{a: 1}` " \
              "because the first rule's write clobbers the second rule's read target before it runs (the exact " \
              "bug fixed for Lineage#apply_renames). Snapshot every old key's value FIRST, delete all old keys, " \
              "then write all new keys, so the pass applies as one simultaneous permutation instead of a " \
              "sequence of edits each stepping on the last."

        RESTRICT_ON_SEND = [:[]=].freeze

        LOOP_METHODS = %i[
          each each_pair each_with_index each_with_object with_index
          map collect flat_map each_entry each_key each_value
          inject reduce each_slice each_cons
        ].freeze

        # `hash[new_name] = hash.delete(old_name)` parses as a `send`
        # node (indexed assignment has no dedicated node type in Ruby's
        # own grammar): `(send recv :[]= new_key (send recv2 :delete
        # old_key))`. `$_recv`/`$_recv2` are captured (not merely
        # matched) so `same_receiver?` below can compare them
        # structurally — node-pattern has no built-in "same subtree
        # twice" backreference, so the equality check is real Ruby, not
        # the pattern itself.
        def_node_matcher :rename_write?, <<~PATTERN
          (send $_recv :[]= _new_key (send $_recv2 :delete _old_key))
        PATTERN

        def on_send(node)
          rename_write?(node) do |recv, recv2|
            next unless same_receiver?(recv, recv2)
            next unless in_loop?(node)

            add_offense(node, message: format(MSG, recv: recv.source))
          end
        end

        private

        # Structural equality (type + children, recursively) — exactly
        # what `Parser::AST::Node#==` already gives, ignoring source
        # location, so `state` vs `state` (two separate `send(nil,
        # :state)` reader calls) and `@state` vs `@state` both count as
        # "the same collection", not just an identical local variable.
        def same_receiver?(recv, recv2)
          recv == recv2
        end

        # Walks every ancestor looking for something that iterates —
        # not just the immediate parent, since the offending assignment
        # may sit one or more non-loop nodes deep inside a loop's block
        # (an `if` guarding it, say) and still carries the exact same
        # hazard.
        def in_loop?(node)
          node.each_ancestor(:block, :numblock, :for, :while, :until, :while_post, :until_post).any? do |ancestor|
            loop_ancestor?(ancestor)
          end
        end

        def loop_ancestor?(ancestor)
          case ancestor.type
          when :for, :while, :until, :while_post, :until_post
            true
          when :block, :numblock
            send_node = ancestor.send_node
            send_node.send_type? && LOOP_METHODS.include?(send_node.method_name)
          end
        end
      end
    end
  end
end
