# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # Why a pending subject needs no fixer: its run's ending event, the tap line that settled it,
      # or its row's `settled_read` saying it settled. It reads what it is given and writes nothing.
      class Settling
        # @param standing [Standing] what the tap says about the stalls
        # @param read [#call] a row's `settled_read` for an opening line's links ({SettledReads})
        def initialize(standing, read)
          @standing = standing
          @read = read
        end

        # @param entry [Array] a pending `[kind, subject, at, branch, links]`
        # @return [String, nil] the reason in words; nil while a fixer is still needed
        def why(entry)
          kind, subject, at, branch, links = entry
          ended = @standing.ending(kind, subject, at)
          return "its run recorded #{ended}" if ended

          settled = @standing.settled(kind, subject, at, branch) || @read.call(kind, links || {})
          settled && "it settled: #{settled}"
        end
      end
    end
  end
end
