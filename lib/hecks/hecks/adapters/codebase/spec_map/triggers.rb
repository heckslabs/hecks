# frozen_string_literal: true

require_relative "../../../../rust_build/session_build"

module Hecks
  module Adapters
    module Codebase
      class SpecMap
        # The rule that a change to some paths runs named specs no file name or text points at: the
        # Tickets world's `triggered_specs` row (`paths` are `File.fnmatch` patterns relative to the
        # root, `specs` the spec files they run). A world that names no such row, or cannot be
        # read, takes `DEFAULTS` (the path rule only; the `always` list lives in the world alone).
        # A row may also carry `always`: specs that run for every change outside `docs/`, as the
        # `:repo_scan` specs do, but unlike them they obey the skip rules.
        class Triggers
          # The Tickets world verb that carries the rule.
          VERB = "triggered_specs"

          # The rule when the world names none.
          DEFAULTS = {
            paths: %w[lib/hecks/**/*.bluebook lib/hecks/**/*.hecksagon **/*.behaviors lib/hecks/hecks/tickets.world],
            specs: %w[spec/behaviors_examples_spec.rb spec/ir_golden_spec.rb]
          }.freeze

          # How a pattern matches: `**/` spans directories, `*` stays inside one.
          FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

          # @param root [String] the tree whose world is read and whose specs must exist
          def initialize(root)
            @root = root
          end

          # @param changed [Array<String>] changed paths relative to the root
          # @return [Array<String>] the rule's specs present in the tree when a changed path matches
          #   a pattern, and the `always` specs when a path lies outside `docs/`
          def specs(changed)
            triggered = matched?(changed) ? Array(rule[:specs]) : []
            always = outside_docs?(changed) ? Array(rule[:always]) : []
            present(triggered) | present(always)
          end

          private

          def matched?(changed) = changed.any? { |path| patterns.any? { |pattern| File.fnmatch?(pattern, path, FLAGS) } }

          def outside_docs?(changed) = changed.any? { |path| !path.start_with?("docs/") }

          def present(specs) = specs.map(&:to_s).select { |spec| File.file?(File.join(@root, spec)) }

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
