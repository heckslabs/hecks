module Hecks
  module Bluebook
    module MetaValidator
      module VerdictCache
        # The encoded `[key, verdict]` pairs of the verdict file. A verdict is keyed by its
        # bluebook's IR, so one read from the file never changes: it is written back as it was
        # read, and only the verdicts this process judged are encoded and checked to round-trip.
        module StoredPairs
          # @return [Array<Array>, nil] every pair the file should hold, or nil when a verdict this
          #   process judged does not round-trip
          def stored_pairs
            fresh = entries.reject { |key, held| read_pairs.key?(key) || !encodable?(held) }
            encoded = encode(fresh)
            return unless decode(encoded) == fresh

            entries.keys.filter_map { |key| read_pairs[key] }.concat(encoded["$h"])
          end

          # @return [Hash{String => Array}] the encoded pair of each verdict read from the file
          def read_pairs = @read_pairs ||= {}
        end
      end
    end
  end
end
