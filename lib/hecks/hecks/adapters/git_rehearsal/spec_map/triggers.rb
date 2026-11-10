# frozen_string_literal: true

require_relative "../../../../rust_build/session_build"

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The rule that a change to some paths runs named specs no file name or text points at: the
        # Tickets world's `triggered_specs` row (`paths` are `File.fnmatch` patterns relative to the
        # root, `specs` the spec files they run). A world that names no such row, or cannot be
        # read, takes `DEFAULTS`, the rule `tickets.world` sets, so it is never silently off.
        class Triggers
          # The Tickets world verb that carries the rule.
          VERB = "triggered_specs"

          # The rule when the world names none.
          DEFAULTS = {
            paths: %w[lib/hecks/**/*.bluebook lib/hecks/**/*.hecksagon **/*.behaviors lib/hecks/hecks/tickets.world],
            specs: %w[spec/behaviors_examples_spec.rb]
          }.freeze

          # How a pattern matches: `**/` spans directories, `*` stays inside one.
          FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

          # @param root [String] the tree whose world is read and whose specs must exist
          def initialize(root)
            @root = root
          end

          # @param changed [Array<String>] changed paths relative to the root
          # @return [Array<String>] the rule's specs present in the tree when a changed path matches
          #   a pattern, else none
          def specs(changed)
            return [] unless changed.any? { |path| patterns.any? { |pattern| File.fnmatch?(pattern, path, FLAGS) } }

            Array(rule[:specs]).map(&:to_s).select { |spec| File.file?(File.join(@root, spec)) }
          end

          private

          def patterns = Array(rule[:paths]).map(&:to_s)

          def rule
            @rule ||= begin
              declared = RustBuild::SessionBuild.world_row(@root, VERB)
              declared[:paths] && declared[:specs] ? declared : DEFAULTS
            end
          end
        end
      end
    end
  end
end
