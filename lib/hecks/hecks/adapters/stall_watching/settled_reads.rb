# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class StallWatching
      # The `settled_read` reads a `StallKind` row may name: each settles a subject the tap cannot,
      # by reading the machine at look time and changing nothing. `boarded-on-origin` asks git
      # whether the commit the opening line links as `boarded` is on the local `origin/main`
      # (`git merge-base --is-ancestor`, no fetch); a stale ref or a failed read is "not settled".
      class SettledReads
        # The reads a row may name.
        NAMES = %w[boarded-on-origin].freeze

        # @param origin [#call, nil] answers whether a commit is on origin/main (true, false or nil
        #   when unknown); git through {Shell} in the working directory when nil
        def initialize(origin: nil)
          @origin = origin || ->(sha) { self.class.on_origin?(Shell.new, sha) }
          @seen = {}
        end

        # @param shell [#capture] runs git
        # @param sha [String] a commit
        # @return [Boolean, nil] true when it is an ancestor of origin/main, false when it is not,
        #   nil when git could not say
        def self.on_origin?(shell, sha)
          result = shell.capture("git", "merge-base", "--is-ancestor", sha, "origin/main")
          { 0 => true, 1 => false }[result.exit_code]
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
          "its boarded commit #{sha} is on origin/main" if @seen[sha] == true
        end
      end
    end
  end
end
