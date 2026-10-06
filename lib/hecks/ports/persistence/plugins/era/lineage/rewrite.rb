module Hecks
  module Ports
    module Persistence
      class Lineage
        # The reference semantics of rename, move, convert, drop and backfill, applied in that
        # order to a deep copy of one entry's state.
        module Rewrite
          private

          def rewrite(state)
            apply_renames(state, @renames)
            @moves.each { |move| apply_move(state, move) }
            @converts.each { |convert| apply_convert(state, convert) }
            @drops.each { |name| apply_drop(state, name) }
            # Only fills a gap nothing else already filled; dotted-path aware, like apply_drop.
            @rules.backfills.each { |backfill| apply_backfill(state, backfill) }
            state
          end

          def deep_dup(node)
            case node
            when Hash then node.transform_values { |value| deep_dup(value) }
            when Array then node.map { |item| deep_dup(item) }
            else node
            end
          end

          # Snapshots every rename's old key/value before writing any new key, so a
          # swap (:a<->:b) applies as one permutation instead of losing data when one
          # rule's destination is another's source.
          def apply_renames(state, renames)
            snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
            snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
            # Every delete finishes before any write, or a swap's first write becomes its
            # second delete target.
            state.merge!(snapshot.to_h { |_old_name, new_name, value| [new_name, value] })
          end

          def apply_drop(state, name)
            top, member = name.to_s.split(".", 2)
            top = top.to_sym
            return state.delete(top) unless member

            nested = state[top]
            return unless nested.is_a?(Hash)

            nested.delete(member)
            state.delete(top) if nested.empty?
          end

          # Dotted-path aware; must stay in step with `hecks_tr_insert` in rule_compiler.rb.
          def apply_backfill(state, backfill)
            name = backfill.name.to_s
            top, member = name.split(".", 2)
            top = top.to_sym

            if member
              nested = (state[top] ||= {})
              nested[member] = backfill.default unless nested.key?(member)
            else
              state[top] = backfill.default unless state.key?(top)
            end
          end

          # Runs on raw rows, before the state codec decodes anything — decode is
          # always the last step, so this never sees an adapter's deep-symbolized entry.
          def apply_move(state, move)
            old_top, old_member = move.from.split(".", 2)
            new_top, new_member = move.to.split(".", 2)
            old_top = old_top.to_sym

            value, present = extract(state, old_top, old_member)
            return unless present

            insert(state, new_top.to_sym, new_member, value, rule: "move #{move.from} to: #{move.to}")
          end

          # A convert is a move whose value has nothing in common with its replacement.
          def apply_convert(state, convert)
            old_top, old_member = convert.from.split(".", 2)
            new_top, new_member = convert.to.split(".", 2)

            raw, present = extract(state, old_top.to_sym, old_member)
            return unless present

            insert(state, new_top.to_sym, new_member, converted(convert, raw), rule: "convert #{convert.from} to: #{convert.to}")
          end

          # A value missing from the lookup table refuses loudly rather than carry an
          # unrecognized value silently into the new era.
          def converted(convert, raw)
            return convert.values[raw] if convert.values.key?(raw)

            raise Runtime::WiringError,
                  "cannot translate #{convert.from}: #{raw.inspect} has no mapping in its " \
                  "convert's values: table. Add #{raw.inspect} => ... to cover it."
          end

          def extract(state, top, member)
            return [nil, false] unless state.key?(top)
            return [state.delete(top), true] unless member

            nested = state[top]
            return [nil, false] unless nested.is_a?(Hash) && nested.key?(member)

            value = nested.delete(member)
            state.delete(top) if nested.empty?
            [value, true]
          end

          # A destination already holding a non-Hash value (e.g. a bare reference id)
          # must not be silently nested under — that would be an undeclared drop. The
          # SQL half (`hecks_tr_insert`) refuses with identical wording.
          def insert(state, top, member, value, rule:)
            return state[top] = value unless member

            if state.key?(top) && !state[top].is_a?(Hash)
              raise Runtime::WiringError,
                    "cannot #{rule}: #{top} already holds #{state[top].inspect}, not a value this can nest " \
                    "under — moving into it would discard that value silently. Rename or drop #{top} first."
            end

            state[top] ||= {}
            state[top][member] = value
          end
        end
      end
    end
  end
end
