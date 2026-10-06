module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # The checks every box setting goes through: a pattern, a bounded integer, a boolean, a
          # map of strings. Extended onto `Settings`; each raises `ArgumentError` naming the
          # setting.
          module Checks
            def string_map(key, value, key_pattern, value_pattern)
              raise ArgumentError, "#{key}: expected a hash" unless value.is_a?(Hash)

              value.to_h { |k, v| [check(key, k.to_s, key_pattern), check(key, v.to_s, value_pattern)] }
            end

            def check(key, value, pattern)
              return value if value.is_a?(String) && value.match?(pattern)

              raise ArgumentError, "#{key}: #{value.inspect} does not match #{pattern.inspect}"
            end

            def integer(key, value, low, high)
              return value if value.is_a?(Integer) && value.between?(low, high)

              raise ArgumentError, "#{key}: #{value.inspect} must be an integer from #{low} to #{high}"
            end

            def boolean(key, value)
              return value if [true, false].include?(value)

              raise ArgumentError, "#{key}: #{value.inspect} must be true or false"
            end
          end
        end
      end
    end
  end
end
