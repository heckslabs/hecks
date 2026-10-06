module Hecks
  module Fuzzing
    module Mutation
      # Each finder looks at one line of a `SourceMap` and answers the changes that apply there, as
      # `{ operator:, removed:, replacement: }` hashes; `Operators` turns them into `Site`s.
      module Finders
        # The shape of a change: a line (or block) taken out, or a line written differently.
        module Change
          module_function

          def removal(operator, length = 1) = { operator: operator, removed: length, replacement: [] }

          def rewrite(operator, line) = { operator: operator, removed: 1, replacement: [line] }
        end

        # Rules a command or value object enforces: `given`, `invariant`, comparisons, query bounds,
        # an attribute's `pattern:` and `one_of:`.
        module Rules
          RULE = /\A\s*(given|invariant)\b.*\{.*\}\s*\z/
          COMPARISONS = { " >= " => " > ", " > " => " >= ", " <= " => " < ", " < " => " <= ",
                          " == " => " != ", " != " => " == " }.freeze
          PATTERN = /,\s*pattern:\s*'[^']*'/
          CLOSED_SET = /,\s*one_of:\s*\[[^\]]*\]/
          BOUND = /\A\s*where\(.*\b(lt|gt):/

          module_function

          def at(map, index)
            line = map.lines[index]
            rule(line) + attribute(line) + query_bound(line)
          end

          def rule(line)
            return [] unless line.match?(RULE)

            flipped = flip_comparison(line)
            [Change.removal(:"drop_#{line[RULE, 1]}"), (Change.rewrite(:flip_comparison, flipped) if flipped)].compact
          end

          # The first comparison inside the line's braces, moved one step.
          def flip_comparison(line)
            body = line[/\{.*\}/]
            operator = COMPARISONS.keys.find { |candidate| body.include?(candidate) }
            operator && line.sub(body, body.sub(operator, COMPARISONS.fetch(operator)))
          end

          def attribute(line)
            return [] unless line.match?(/\A\s*attribute\b/)

            [[:drop_pattern, PATTERN], [:drop_one_of, CLOSED_SET]].filter_map do |operator, shape|
              (found = line[shape]) && Change.rewrite(operator, line.sub(found, ""))
            end
          end

          def query_bound(line)
            return [] unless line.match?(BOUND)

            [Change.rewrite(:flip_query_bound, line.sub(/\b(lt|gt):/) { Regexp.last_match(1) == "lt" ? "gt:" : "lt:" })]
          end
        end

        # The shape of the domain: `from:` guards, `sets`, lifecycle targets, emitted events.
        module Structure
          GUARD = /,\s*from:\s*"[^"]*"/

          module_function

          def at(map, index)
            line = map.lines[index]
            scope = map.scope(index)
            sets(line, scope) + command_guard(line) + transition(map, line, scope) + emits(map, line)
          end

          def sets(line, scope)
            line.match?(/\A\s*sets\s+:\w+\s*\z/) && scope == "command" ? [Change.removal(:drop_sets)] : []
          end

          def command_guard(line)
            guard = line[GUARD]
            guard && line.match?(/\A\s*command\b.*\bdo\s*\z/) ? [Change.rewrite(:drop_from_guard, line.sub(guard, ""))] : []
          end

          def transition(map, line, scope)
            match = line.match(SourceMap::TRANSITION)
            return [] unless match && scope == "lifecycle"

            [retarget(map, line, match[3]), guard(line, match[4])].compact
          end

          def retarget(map, line, target)
            other = map.states.find { |state| state != target }
            other && Change.rewrite(:retarget_transition, line.sub("=> \"#{target}\"", "=> \"#{other}\""))
          end

          def guard(line, rest)
            found = rest[GUARD]
            found && Change.rewrite(:drop_from_guard, line.sub(found, ""))
          end

          def emits(map, line)
            match = line.match(SourceMap::EMITS)
            other = match && map.emitted.find { |name| name != match[2] }
            other ? [Change.rewrite(:swap_emits, "#{match[1]}emits #{other}\n")] : []
          end
        end

        # Reactions: whole policies, and what a process manager does on each of its transitions.
        module Reactions
          module_function

          def at(map, index)
            line = map.lines[index]
            scope = map.scope(index)
            policy(map, index, line) + saga_transition(map, index, line, scope) + saga_dispatch(line, scope)
          end

          def policy(map, index, line)
            length = line.match?(/\A\s*policy\s+"/) && map.block_length(index)
            length ? [Change.removal(:drop_policy, length)] : []
          end

          def saga_transition(map, index, line, scope)
            length = scope == "process_manager" && line.match?(/\A\s*transition\b.*\bdo\s*\z/) && map.block_length(index)
            length ? [Change.removal(:drop_saga_transition, length)] : []
          end

          def saga_dispatch(line, scope)
            scope == "transition" && line.match?(/\A\s*dispatch\s+\S/) ? [Change.removal(:drop_saga_dispatch)] : []
          end
        end

        ALL = [Rules, Structure, Reactions].freeze
      end
    end
  end
end
