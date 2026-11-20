# frozen_string_literal: true

require "digest"

module Hecks
  module Adapters
    class StallWatching
      # The key a stall or an impediment is known by: `stall-<kind>-<subject>`, held to the
      # longest Work id a look files. Past the limit the tail is a digest of the whole, so two
      # long subjects never share a key.
      module Key
        # The longest key, and so Work id, a look files.
        LIMIT = 120

        # @param kind [String] a row's kind
        # @param subject [String] what the row's line is about
        # @return [String] `stall-<kind>-<subject>`, its tail a digest when it is past the limit
        def self.of(kind, subject)
          full = "stall-#{kind}-#{subject}"
          return full if full.length <= LIMIT

          "#{full[0, LIMIT - 17]}-#{Digest::SHA256.hexdigest(full)[0, 16]}"
        end
      end
    end
  end
end
