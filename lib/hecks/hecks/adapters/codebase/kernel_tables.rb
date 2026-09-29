# frozen_string_literal: true

require_relative "tree"
require_relative "../../../kernel_capabilities"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `KernelRun` asks of the working tree: projecting the capability enums the
      # hand-written Rust kernel is matched against, and checking that each capability the grammar
      # admits has its hand-written file.
      #
      # The projection is built in memory by `KernelCapabilities`, the code
      # `bin/project_kernel_capabilities` runs, and compared with the tree; it writes only when
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
          rows = KernelCapabilities.coverage(root: tree.root)
          lines = rows.map do |row|
            "#{row.present ? 'OK  ' : 'MISS'}  #{tree.relative(row.path)}  (#{row.source}: #{row.name.inspect})"
          end
          missing = rows.reject(&:present)
          return [*lines, "", verdict(rows.size)].join("\n") if missing.empty?

          raise ConsoleCapture::Failure, [*lines, "", gaps(missing, tree)].join("\n")
        end

        # @param count [Integer] how many capabilities there are
        # @return [String] the clean verdict
        def verdict(count)
          "#{count}/#{count} kernel capability files present — every attribute shape and " \
            "expression-operator category the live Ruby grammar admits has a rust/src/kernel/ file " \
            "at its conventional path."
        end

        # @param missing [Array<KernelCapabilities::Row>] the capabilities with no file
        # @param tree [Tree] the checkout
        # @return [String] what is missing, one path a line
        def gaps(missing, tree)
          head = "#{missing.size} capability file(s) missing — the grammar admits these but no " \
                 "hand-written Rust interpretation exists for them yet:"
          [head, *missing.map { |row| "  #{tree.relative(row.path)}" }].join("\n")
        end
      end
    end
  end
end
