require_relative "workflow_pagination/statement"
require_relative "workflow_pagination/judge"

module Hecks
  # Finds the GitHub list calls in a workflow that count or wait for items and read only the first
  # page of them.
  #
  # The artifact wait of a CI run counted four named artifacts among a run's list, and went on
  # waiting its full time once the run held 35, because the list pages at 30 and the fourth sat on
  # the second page.
  #
  # @example
  #   WorkflowPagination.check(root: ".")  # => "no workflow counts a GitHub list from its first page"
  module WorkflowPagination
    # The files that hold workflow steps.
    GLOBS = %w[.github/workflows/*.yml .github/workflows/*.yaml .github/actions/**/*.yml .github/actions/**/*.yaml].freeze

    # The clean verdict.
    CLEAN = "no workflow counts a GitHub list from its first page".freeze

    # The words that start an API call in a step.
    CALL = /gh api|api\.github\.com/

    # Raised with every finding.
    class Failure < StandardError; end

    module_function

    # @param root [String] the checkout
    # @return [String] the clean verdict
    # @raise [Failure] with a line for each call that reads one page
    def check(root:)
      found = findings(root)
      raise Failure, found.join("\n") unless found.empty?

      CLEAN
    end

    # @return [Array<String>] `file:line: fault` for each call that reads one page
    def findings(root)
      GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.sort.flat_map do |file|
        faults(file).map { |line, fault| "#{file.delete_prefix("#{root}/")}:#{line}: #{fault}" }
      end
    end

    # @return [Array<Array(Integer, String)>] the line and the fault of each bad call in a file
    def faults(file)
      lines = File.readlines(file, encoding: "UTF-8")
      lines.each_index.filter_map do |index|
        next if lines[index].lstrip.start_with?("#") || !lines[index].match?(CALL)

        call = Statement.new(lines, index)
        fault = Judge.fault(call)
        [call.line, fault] if fault
      end
    end
  end
end
