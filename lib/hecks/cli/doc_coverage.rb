# frozen_string_literal: true

require_relative "../../hecks"
require_relative "../doc/reference"

module Hecks
  module CLI
    # The command behind `bin/doc_coverage`: refuses unless every live word in
    # `docs/implemented/reference/` has prose and a running example. It checks that an example
    # exists; `spec/reference_doctest_spec.rb` checks that it passes. `ruby skip` fences and
    # hidden `<!-- doctest:boot -->` blocks do not count as examples.
    module DocCoverage
      module_function

      # Prints the coverage report.
      #
      # @param root [String] the repository root
      # @param out [IO] where the report goes
      # @param err [IO] where the refusal goes
      # @return [Integer] 0 when every word is covered, 1 otherwise
      def call(root:, out: $stdout, err: $stderr)
        clean, report = Hecks::Doc::Reference.coverage_report(File.join(root, "docs/implemented/reference"))
        out.puts report
        return 0 if clean

        err.puts "docs/implemented/reference/ is behind the language. " \
                 "Regenerate with bin/reference to see the words in place."
        1
      end
    end
  end
end
