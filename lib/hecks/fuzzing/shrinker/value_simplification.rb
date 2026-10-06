module Hecks
  module Fuzzing
    module Shrinker
      # Pass 3 of the shrinker: offers each surviving argument value a simpler stand-in and keeps
      # the ones the finding survives. Split out of `Shrinker` so each file holds one idea.
      module ValueSimplification
        module_function

        # Offers each surviving argument a simpler value, keeping one the finding survives. Nested
        # hashes are simplified key by key; a candidate that stops reproducing is rejected.
        def call(steps, meter, &)
          steps.each_index do |position|
            original = Shrinker.args_of(steps[position])
            next unless original.is_a?(Hash)

            original.each_key do |key|
              steps = simplify_path(steps, position, [key], meter, &)
            end
          end
          steps
        end

        # Simplifies the value at `path` inside step `position`'s arguments, recursing into hashes.
        def simplify_path(steps, position, path, meter, &)
          value = Shrinker.args_of(steps[position]).dig(*path)
          if value.is_a?(Hash)
            return value.each_key.reduce(steps) { |acc, key| simplify_path(acc, position, path + [key], meter, &) }
          end

          simpler_values(value).each do |replacement|
            return steps if meter.exhausted?

            candidate = with_value(steps, position, path, replacement)
            return candidate if meter.try { yield(candidate) }
          end
          steps
        end

        # Simpler stand-ins for `value`, simplest first; none for what is already minimal.
        def simpler_values(value)
          candidates =
            case value
            when String  then ["", value[0].to_s]
            when Integer then [0, 1]
            when Float   then [0.0, 1.0]
            when Array   then [[], value.first(1)]
            else []
            end
          candidates.uniq.reject { |candidate| candidate == value }
        end

        def with_value(steps, position, path, replacement)
          step = steps[position]
          args = Marshal.load(Marshal.dump(Shrinker.args_of(step)))
          parent = path.length > 1 ? args.dig(*path[0...-1]) : args
          parent[path.last] = replacement
          candidate = steps.map(&:dup)
          candidate[position] = step.merge("args" => args)
          candidate
        end
      end
    end
  end
end
