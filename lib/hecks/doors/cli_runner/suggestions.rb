module Hecks
  module Doors
    module CliRunner
      # The answer for a command or question name the chapter does not declare.
      module Suggestions
        module_function

        # Words the answer for an unknown command or question, suggesting up to five near names.
        # Ranked by shared prefix, which survives a dropped letter where a substring match
        # would not.
        def unknown(cli, name, asking, program)
          near  = near_names(cli, name, asking)
          lines = ["no such #{asking ? "query" : "command"}: #{name}"]
          lines += ["", "did you mean:", *near.first(5).map { |candidate| "  #{candidate}" }] unless near.empty?
          lines += ["", "  #{program}#{" query" if asking}   for the full list"]
          lines.join("\n")
        end

        # The names to suggest: those in the other namespace spelled like `name` first, then the
        # ones that share a prefix with it.
        def near_names(cli, name, asking)
          # Both spellings are candidates: `order.create_piza` shares no prefix with `create_pizza`.
          pool = cli[:names][asking ? :question : :command].keys
          # A bare name is the commonest slip now that the aggregate is required: its homes first.
          homes = (pool + cli[:names][asking ? :command : :question].keys)
                  .select { |candidate| candidate.split(".").last == name }.uniq
          homes + (similar(pool, name) - homes)
        end

        # The names in `pool` sharing a long enough prefix with `name`, longest first.
        def similar(pool, name)
          pool.map { |candidate| [shared_prefix(candidate, name), candidate] }
              .select { |shared, _| shared >= [name.length / 2, 3].max }
              .sort_by { |shared, candidate| [-shared, candidate] }
              .map(&:last)
        end

        def shared_prefix(one, other)
          length = [one.length, other.length].min
          (0...length).find { |index| one[index] != other[index] } || length
        end
      end
    end
  end
end
