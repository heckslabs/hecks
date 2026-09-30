# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"
require "hecks/engine_agreement"
require "hecks/doc/reference"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ConformanceRun` asks of the working tree: the checks on the language
      # itself.
      #
      # The query-engine check and the reference-docs check read the tree in this process, with the
      # code their `bin/` scripts run, and write nothing. The argument-gate matrix boots several
      # throwaway domains and replays them, so it runs in a child process; without `confirm` the
      # script only reports, and with it the script rewrites the committed matrix and its fixtures.
      module Conformance
        # Every operation this family carries out.
        OPERATIONS = %w[check_engine_agreement measure_doc_coverage argument_gate_matrix].freeze

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `ConformanceRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture] starts the argument-gate matrix's child process
        # @return [String] what the check found
        # @raise [ConsoleCapture::Failure] when the check finds a disagreement
        def call(operation, held, tree, shell: nil)
          case operation
          when "check_engine_agreement" then engine_agreement(tree)
          when "measure_doc_coverage" then doc_coverage(tree)
          else gate_matrix(held, tree, shell)
          end
        end

        # @param tree [Tree] the checkout
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with every problem, when the engines disagree
        def engine_agreement(tree)
          finding = EngineAgreement.check(root: tree.root)
          return EngineAgreement.clean_line(finding) if finding.problems.empty?

          raise ConsoleCapture::Failure, EngineAgreement.problem_lines(finding)
        end

        # @param tree [Tree] the checkout
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each word that lacks prose or an example
        def doc_coverage(tree)
          clean, report = Doc::Reference.coverage_report(tree.path("docs/implemented/reference"))
          raise ConsoleCapture::Failure, report unless clean

          report
        end

        # @param held [Hash] the record's fields; `confirm` makes the script write
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] starts the child process
        # @return [String] what the script printed: the rows kept and dropped, and what it wrote
        # @raise [ConsoleCapture::Failure] when the script ends badly
        def gate_matrix(held, tree, shell)
          confirm = held[:confirm].is_a?(Hash) ? held[:confirm][:value] : held[:confirm]
          child = RubyChild.new(tree, shell: shell)
          child.answer("argument_gate_matrix", *("--write" if confirm == true))
        end
      end
    end
  end
end
