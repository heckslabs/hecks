module Hecks
  module Projections
    module Deploy
      module Fargate
        # Validation for the optional Fargate settings beyond the baseline ones.
        # Every check raises `ArgumentError` naming the setting it was reading.
        module Check
          module_function

          LOGICAL_ID = /\A[A-Za-z][A-Za-z0-9]*\z/
          RESOURCE_NAME = %r{\A[A-Za-z0-9][A-Za-z0-9_./-]*\z}

          # Checks that a value is a hash with only known keys and returns it symbol-keyed.
          #
          # @param value [Object] the setting as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param allowed [Array<Symbol>] every key the hash may carry
          # @param required [Array<Symbol>] the keys the hash must carry
          # @return [Hash{Symbol => Object}] the hash with its keys as symbols
          # @raise [ArgumentError] if the value is not a hash, names an unknown key, or lacks a
          #   required one
          def hash!(value, where, allowed:, required: [])
            raise ArgumentError, "#{where} must be a hash, got #{value.inspect}" unless value.is_a?(Hash)

            found = value.transform_keys(&:to_sym)
            unknown = found.keys - allowed
            unless unknown.empty?
              raise ArgumentError,
                    "#{where} has unknown key(s) #{unknown.join(', ')}; allowed: #{allowed.join(', ')}"
            end

            missing = required.reject { |key| found.key?(key) }
            raise ArgumentError, "#{where} needs #{missing.join(', ')}" unless missing.empty?

            found
          end

          # Checks that a value is a list of hashes, each valid for `hash!`.
          #
          # @param value [Object] the setting as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param allowed [Array<Symbol>] every key an entry may carry
          # @param required [Array<Symbol>] the keys each entry must carry
          # @return [Array<Hash{Symbol => Object}>] the entries with symbol keys
          # @raise [ArgumentError] if the value is not an array or an entry is invalid
          def hashes!(value, where, allowed:, required: [])
            raise ArgumentError, "#{where} must be a list of hashes, got #{value.inspect}" unless value.is_a?(Array)

            value.each_with_index.map { |entry, index| hash!(entry, "#{where}[#{index}]", allowed: allowed, required: required) }
          end

          # Checks that a value is a CloudFormation logical id.
          #
          # @param value [Object] the id as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @return [String] the id
          # @raise [ArgumentError] if the id has anything but letters and digits, or starts with a
          #   digit
          def logical_id!(value, where)
            text = value.to_s
            return text if LOGICAL_ID.match?(text)

            raise ArgumentError, "#{where} must be a CloudFormation logical id " \
                                 "(letters and digits, starting with a letter), got #{value.inspect}"
          end

          # Checks that a value is a name AWS accepts for a container, repository or stack.
          #
          # @param value [Object] the name as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @return [String] the name
          # @raise [ArgumentError] if the name has characters outside letters, digits and `_ . / -`
          def resource_name!(value, where)
            text = value.to_s
            return text if RESOURCE_NAME.match?(text)

            raise ArgumentError, "#{where} must be a name of letters, digits, and _ . / - characters, got #{value.inspect}"
          end

          # Checks that a value is a whole number in a range.
          #
          # @param value [Object] the number as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param range [Range<Integer>] the accepted values
          # @return [Integer] the number
          # @raise [ArgumentError] if the value is not an integer inside `range`
          def integer!(value, where, range:)
            return value if value.is_a?(Integer) && range.cover?(value)

            raise ArgumentError, "#{where} must be a whole number from #{range.min} to #{range.max}, got #{value.inspect}"
          end

          # Checks that a value is true or false.
          #
          # @param value [Object] the flag as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @return [Boolean] the flag
          # @raise [ArgumentError] if the value is neither `true` nor `false`
          def boolean!(value, where)
            return value if [true, false].include?(value)

            raise ArgumentError, "#{where} must be true or false, got #{value.inspect}"
          end

          # Checks that a value is a list of non-empty strings.
          #
          # @param value [Object] the list as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param min [Integer] the fewest entries allowed
          # @param max [Integer, nil] the most entries allowed, or nil for no limit
          # @return [Array<String>] the entries as strings
          # @raise [ArgumentError] if the value is not a list of strings or is out of size range
          def strings!(value, where, min: 0, max: nil)
            list = value.is_a?(Array) ? value : nil
            ok = list&.all? { |item| (item.is_a?(String) || item.is_a?(Symbol)) && !item.to_s.empty? }
            raise ArgumentError, "#{where} must be a list of strings, got #{value.inspect}" unless ok
            raise ArgumentError, "#{where} needs at least #{min} entr#{min == 1 ? 'y' : 'ies'}" if list.size < min
            raise ArgumentError, "#{where} takes at most #{max} entries, got #{list.size}" if max && list.size > max

            list.map(&:to_s)
          end

          # Checks that a value is a map of names to strings and returns it string-keyed.
          # A `nil` value is kept: the domain container's env setting removes a variable with it.
          #
          # @param value [Object] the map as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param nil_ok [Boolean] whether a `nil` value is accepted
          # @return [Hash{String => Object}] the map with string keys
          # @raise [ArgumentError] if the value is not a hash or a key is not an
          #   environment-variable style name
          def map!(value, where, nil_ok: false)
            raise ArgumentError, "#{where} must be a hash, got #{value.inspect}" unless value.is_a?(Hash)

            value.to_h do |key, item|
              name = key.to_s
              unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
                raise ArgumentError,
                      "#{where} key #{key.inspect} must be a name of letters, digits and underscores"
              end
              raise ArgumentError, "#{where}.#{name} needs a value" if item.nil? && !nil_ok

              [name, item]
            end
          end

          # Checks that a value is one of a fixed set.
          #
          # @param value [Object] the value as written in the world file
          # @param where [String] the setting's name, used in the error message
          # @param choices [Array<String>] the accepted values
          # @return [String] the value as a string
          # @raise [ArgumentError] if the value is not among `choices`
          def one_of!(value, where, choices)
            return value.to_s if choices.include?(value.to_s)

            raise ArgumentError, "#{where} must be one of #{choices.join(', ')}, got #{value.inspect}"
          end
        end
      end
    end
  end
end
