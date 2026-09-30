# frozen_string_literal: true

require_relative "tree"
require "hecks/kernel_capabilities"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `KernelRun` asks of the working tree: projecting the capability enums the
      # hand-written Rust kernel is matched against, and checking that each capability the grammar
      # admits has its hand-written file.
      #
      # The projection is built in memory by `KernelCapabilities`, the code
      # `hecks project_kernel_capabilities` runs, and compared with the tree; it writes only when
      # confirmed. The coverage check reads the tree and writes nothing.
      module KernelTables
        # Every operation this family carries out.
        OPERATIONS = %w[project_kernel_capabilities measure_kernel_coverage].freeze

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `KernelRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture] unused; the family starts no child process
        # @return [String] the drift report, or the coverage report
        # @raise [ConsoleCapture::Failure] when a capability has no kernel file
        def call(operation, held, tree, shell: nil)
          _ = shell
          confirm = (held[:confirm].is_a?(Hash) ? held[:confirm][:value] : held[:confirm]) == true
          return coverage(tree) if operation == "measure_kernel_coverage"

          result = KernelCapabilities.build(root: tree.root)
          tree.apply(result.content, stale: result.stale, confirm: confirm)
        end

        # Lists every capability the live grammar admits with whether its file is there.
        #
        # @param tree [Tree] the checkout
        # @return [String] one line for each capability, and a verdict
        # @raise [ConsoleCapture::Failure] when any capability has no file
        def coverage(tree)
          lines, verdict, complete = KernelCapabilities.coverage_report(root: tree.root)
          report = [lines, "", verdict].join("\n")
          return report if complete

          raise ConsoleCapture::Failure, report
        end
      end
    end
  end
end
