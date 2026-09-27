module RuboCop
  module Cop
    module Hecks
      # Flags `hash[new] = hash.delete(old)` inside a loop.
      # Applying renames one at a time to the hash being read loses data on swaps and chains.
      #
      # @example
      #   # bad
      #   renames.each { |old, new| state[new] = state.delete(old) }
      #
      #   # good: snapshot the values, delete every old key, then write the new keys
      #   pairs = renames.select { |old, _| state.key?(old) }.map { |old, new| [new, state[old]] }
      #   renames.each_key { |old| state.delete(old) }
      #   pairs.each { |new, value| state[new] = value }
      class SequentialHashRenameInLoop < Base
        MSG = "`%<recv>s[new] = %<recv>s.delete(old)` inside a loop applies one rename at a time against the " \
              "SAME hash it reads from — a swap (`{a: :b, b: :a}`) on `{a: 1, b: 2}` collapses to `{a: 1}` " \
              "because the first rule's write clobbers the second rule's read target before it runs (the exact " \
              "bug fixed for Lineage#apply_renames). Snapshot every old key's value FIRST, delete all old keys, " \
              "then write all new keys, so the pass applies as one simultaneous permutation instead of a " \
              "sequence of edits each stepping on the last.".freeze

        RESTRICT_ON_SEND = [:[]=].freeze

        LOOP_METHODS = %i[
          each each_pair each_with_index each_with_object with_index
          map collect flat_map each_entry each_key each_value
          inject reduce each_slice each_cons
        ].freeze

        # Indexed assignment parses as a `send`. Both receivers are captured because node-pattern
        # has no backreference; `same_receiver?` compares them.
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

        def same_receiver?(recv, recv2)
          recv == recv2
        end

        # Checks every ancestor: a guard node may sit between the assignment and the loop block.
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
