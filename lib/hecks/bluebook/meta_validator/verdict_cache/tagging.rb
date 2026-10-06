module Hecks
  module Bluebook
    module MetaValidator
      module VerdictCache
        # The tagged-JSON encoding verdicts are stored in: what JSON would lose (a symbol, a
        # hash's key types and order) is tagged so it round-trips exactly.
        module Tagging
          # Encodes plain data as JSON-safe data, tagging what JSON would lose:
          # a symbol is `{"$s" => name}`, a hash is `{"$h" => [[key, value], ...]}`
          # (pair order is hash order).
          #
          # @param obj [Object] Hash, Array, String, Symbol, Integer, nil, true or false
          # @return [Object] the tagged form
          # @raise [ArgumentError] for any other class
          def encode(obj)
            case obj
            when Symbol then { "$s" => obj.to_s }
            when Hash then { "$h" => obj.map { |key, value| [encode(key), encode(value)] } }
            when Array then obj.map { |item| encode(item) }
            when *SCALARS then encode_scalar(obj)
            else raise ArgumentError, "unencodable #{obj.class}"
            end
          end

          # The classes JSON carries as they are, a string once its encoding is checked.
          SCALARS = [String, Integer, NilClass, TrueClass, FalseClass].freeze

          # @param obj [String, Integer, nil, true, false] a scalar
          # @return [Object] `obj`, when JSON carries it back unchanged
          # @raise [ArgumentError] for a string that is not valid text
          def encode_scalar(obj)
            plain = !obj.is_a?(String) || (obj.valid_encoding? && (obj.ascii_only? || obj.encoding == Encoding::UTF_8))
            raise ArgumentError, "unencodable string" unless plain

            obj
          end

          # The inverse of `encode`.
          #
          # @param obj [Object] the tagged form
          # @return [Object] the original data
          def decode(obj)
            case obj
            when Array then obj.map { |item| decode(item) }
            when Hash then decode_tagged(obj)
            else obj
            end
          end

          # @param obj [Hash] a one-entry hash tagged `$s` or `$h`
          # @return [Symbol, Hash] what the tag stands for
          # @raise [ArgumentError] for any other hash
          def decode_tagged(obj)
            return obj["$s"].to_sym if obj.size == 1 && obj.key?("$s")
            return obj["$h"].to_h { |key, value| [decode(key), decode(value)] } if obj.size == 1 && obj.key?("$h")

            raise ArgumentError, "untagged hash"
          end
        end
      end
    end
  end
end
