# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # How a `StallKind` row says its stall is cleared, read from its `cleared_by`: by its stall
      # item, which a look files, or by a call for help, which no look files. One path per row.
      module Clearing
        ITEM = "item"
        HELP = "help"

        # @param kind [Hash] a `StallKind` row
        # @return [String] "item" for a row that names it or names nothing, "help" for a row
        #   cleared by a call for help
        # @raise [ArgumentError] when the row names any other value
        def self.of(kind)
          named = kind[:cleared_by].to_s
          return ITEM if named.empty? || named == ITEM
          return HELP if named == HELP

          raise ArgumentError, "the row #{kind[:kind]} is cleared by #{named.inspect}: it is #{ITEM} or #{HELP}"
        end

        # @param kind [Hash] a `StallKind` row
        # @return [Boolean] whether a call for help clears the row's stall, so no look files it
        def self.help?(kind) = of(kind) == HELP
      end
    end
  end
end
