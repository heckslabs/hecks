# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class Impacted
        # Which specs a rehearsal cannot run here: those that need `cargo`, `gh` or the network, and
        # those tagged `:io` when no scratch Postgres answers. Only code lines are read, never
        # comments, and `gh` counts as needed only where a process launcher or a backtick runs it
        # by name, so a spec that fakes `gh` (a runner it is given, an argv it expects) is not
        # skipped. A launch that carries no literal `gh` (`system(gh_bin)`) is not seen.
        class Skips
          NEEDS = {
            "cargo"   => /\bcargo (?:build|test|run|check)|["']cargo["']/,
            "gh"      => /\b(?:system|spawn|exec|popen\d?|capture\w*)\s*\(?\s*\[?\s*["']gh["']|`gh\s|%x[\[({]gh\s/,
            "network" => /Net::HTTP|URI\.open|open-uri|\bcurl\b/
          }.freeze
          TAGGED_IO = /\bio: true\b|,\s*:io\b/
          COMMENT = /\A\s*#.*|\s#(?!\{)[^"'`]*\z/
          NO_POSTGRES = "no scratch Postgres"

          # @param root [String] the tree the specs are read from
          # @param scratch [#call] says whether a scratch Postgres is reachable
          def initialize(root, scratch:)
            @root = root
            @scratch = scratch
          end

          # @param spec [String] a spec file relative to the root
          # @return [String, nil] why it cannot run here, naming the line that needs it, or nil
          def call(spec)
            text = File.read(File.join(@root, spec)).scrub
            needed(code_lines(text)) || (NO_POSTGRES if tagged_io?(text) && !reachable?)
          end

          # @return [Boolean] whether the spec has `:io` examples
          def io?(spec) = tagged_io?(File.read(File.join(@root, spec)).scrub)

          private

          def code_lines(text) = text.lines.map { |line| line.sub(COMMENT, "").strip }.reject(&:empty?)

          def needed(code)
            NEEDS.each do |need, pattern|
              line = code.find { |l| pattern.match?(l) }
              return "needs #{need}: #{line}" if line
            end
            nil
          end

          def tagged_io?(text) = TAGGED_IO.match?(text)

          def reachable? = @reachable.nil? ? (@reachable = @scratch.call) : @reachable
        end
      end
    end
  end
end
