# frozen_string_literal: true

require_relative "../main_integration/carried_check"

module Hecks
  module Adapters
    class StallWatching
      # The `settled_read` reads a `StallKind` row may name: each settles a subject the tap cannot,
      # by reading the machine at look time and changing nothing. `boarded-on-origin` asks
      # {MainIntegration::CarriedCheck} whether `origin/main`, as last fetched, holds the commit the
      # opening line links as `boarded`; a stale ref or a commit git cannot place is "not settled".
      class SettledReads
        # The reads a row may name.
        NAMES = %w[boarded-on-origin].freeze

        # @param origin [#call, nil] answers whether a commit is on origin/main, truthy when it is;
        #   {MainIntegration::CarriedCheck} on the working directory's checkout when nil
        def initialize(origin: nil)
          @origin = origin || ->(sha) { MainIntegration::CarriedCheck.new(Dir.pwd).by_known(sha) }
          @seen = {}
        end

        # @param kind [Hash] a `StallKind` row
        # @param links [Hash] the links of the subject's opening line
        # @return [String, nil] what settled the subject, in words; nil when the row names no read
        #   or the read says it has not settled
        # @raise [ArgumentError] when the row names a read this adapter does not know
        def call(kind, links)
          name = kind[:settled_read].to_s
          return if name.empty?
          raise ArgumentError, "unknown settled_read #{name.inspect}: one of #{NAMES.join(", ")}" unless NAMES.include?(name)

          boarded(links.to_h["boarded"].to_s)
        end

        private

        def boarded(sha)
          return if sha.empty?

          @seen[sha] = @origin.call(sha) unless @seen.key?(sha)
          "its boarded commit #{sha} is on origin/main" if @seen[sha]
        end
      end
    end
  end
end
