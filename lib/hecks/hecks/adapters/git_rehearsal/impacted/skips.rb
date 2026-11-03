# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class Impacted
        # Which specs a rehearsal cannot run here: those that need `cargo`, `gh` or the network, and
        # those tagged `:io` when no scratch Postgres answers.
        class Skips
          NEEDS = {
            "cargo"   => /\bcargo (?:build|test|run|check)|["']cargo["']/,
            "gh"      => /["'`]gh["'`]|`gh |\bgh (?:pr|run|api|workflow|issue)\b/,
            "network" => /Net::HTTP|URI\.open|open-uri|\bcurl\b/
          }.freeze
          TAGGED_IO = /\bio: true\b|,\s*:io\b/
          NO_POSTGRES = "no scratch Postgres"

          # @param root [String] the tree the specs are read from
          # @param scratch [#call] says whether a scratch Postgres is reachable
          def initialize(root, scratch:)
            @root = root
            @scratch = scratch
          end

          # @param spec [String] a spec file relative to the root
          # @return [String, nil] why it cannot run here, or nil
          def call(spec)
            text = File.read(File.join(@root, spec)).scrub
            found = NEEDS.find { |_need, pattern| pattern.match?(text) }
            return "needs #{found.first}" if found

            NO_POSTGRES if tagged_io?(text) && !reachable?
          end

          # @return [Boolean] whether the spec has `:io` examples
          def io?(spec) = tagged_io?(File.read(File.join(@root, spec)).scrub)

          private

          def tagged_io?(text) = TAGGED_IO.match?(text)

          def reachable? = @reachable.nil? ? (@reachable = @scratch.call) : @reachable
        end
      end
    end
  end
end
