module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Words the answer for a command or question the chapter does not declare. Extended into
        # `CliRunner`.
        module Suggestions
          # Words the answer for an unknown command or question, suggesting up to five near names.
          # Ranked by shared prefix, which survives a dropped letter where a substring would not.
          def unknown(cli, name, asking, program)
            near  = near_names(cli, name, asking)
            lines = ["no such #{asking ? "query" : "command"}: #{name}"]
            lines += ["", "did you mean:", *near.first(5).map { |candidate| "  #{candidate}" }] unless near.empty?
            lines += ["", "  #{program}#{" query" if asking}   for the full list"]
            lines.join("\n")
          end

          # The names worth suggesting: the bare name's homes first, then the names sharing a
          # prefix.
          def near_names(cli, name, asking)
            # Both spellings are candidates: `order.create_piza` shares no prefix with
            # `create_pizza`.
            pool = cli[:names][asking ? :question : :command].keys
            # A bare name is the commonest slip now that the aggregate is required: its homes first.
            homes = (pool + cli[:names][asking ? :command : :question].keys)
                    .select { |candidate| candidate.split(".").last == name }.uniq
            homes + (similar_names(pool, name) - homes)
          end

          # The pool's names that share at least half of `name` (and three letters) as a prefix.
          def similar_names(pool, name)
            pool.map { |candidate| [shared_prefix(candidate, name), candidate] }
                .select { |shared, _| shared >= [name.length / 2, 3].max }
                .sort_by { |shared, candidate| [-shared, candidate] }
                .map(&:last)
          end

          # The length of the prefix two words share.
          def shared_prefix(one, other)
            length = [one.length, other.length].min
            (0...length).find { |index| one[index] != other[index] } || length
          end
        end
      end
    end
  end
end
