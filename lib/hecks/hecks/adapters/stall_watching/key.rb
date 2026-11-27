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

        # @param stall [String] a stall's key, which is also the key of the run that fixes it
        # @return [String] the sentences that close a stall's detail: the exact command that reads
        #   its row, and the rule that no move stops a session
        def self.reading(stall)
          "Read your row: exe/hecks StallWatch.impediments run=<your run key> stall=#{stall}. " \
            "Never stop or kill a session."
        end
      end
    end
  end
end
