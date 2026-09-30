# frozen_string_literal: true

require_relative "../../hecks"
require_relative "../engine_agreement"

module Hecks
  module CLI
    # The command behind `bin/check_engine_agreement`: fails when a query engine re-grows its
    # own comparator dispatch, or when a declared comparator lacks a shared `Comparison` case or
    # a cross-engine agreement spec. Grep-based.
    module CheckEngineAgreement
      module_function

      # Checks the tree and prints the verdict.
      #
      # @param root [String] the repository root to check
      # @param out [IO] where a clean verdict goes
      # @param err [IO] where the problems go
      # @return [Integer] 0 when clean, 1 with problems
      def call(root:, out: $stdout, err: $stderr)
        finding = Hecks::EngineAgreement.check(root: root)
        if finding.problems.empty?
          out.puts Hecks::EngineAgreement.clean_line(finding)
          return 0
        end

        err.puts Hecks::EngineAgreement.problem_lines(finding)
        1
      end
    end
  end
end
