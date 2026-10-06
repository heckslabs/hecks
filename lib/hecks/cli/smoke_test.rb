require_relative "../../hecks"
require_relative "../bluebook/smoke_test"

module Hecks
  module CLI
    # The command behind `hecks smoke_test`: boots a real domain
    # and dispatches one synthesized call per declared command and report
    # (`Bluebook::SmokeTest`), printing every failure rather than the first.
    #
    # Needs a real `.hecksagon`; a failure may be a domain bug or a value the
    # synthesizer's naive choices cannot satisfy — smoke-testing proves nothing
    # crashes, not that an answer is right.
    module SmokeTest
      module_function

      def call(argv, root:)
        missing = argv.reject { |dir| File.directory?(dir) }
        abort "smoke_test: no such domain #{missing.first.inspect}" unless missing.empty?

        targets = targets_for(argv, root)
        abort "no wired example domains found (none of examples/* has a .hecksagon)" if targets.empty?

        finish(targets.reduce(true) { |all_ok, dir| clean?(dir) && all_ok })
      end

      # Prints the verdict and exits with its status.
      #
      # @api private
      def finish(passed)
        puts
        puts passed ? "Every declared command and report dispatched cleanly." : "SMOKE TEST FOUND PROBLEMS."
        exit(passed ? 0 : 1)
      end

      # The named domains, or every wired example under `root` when none is named.
      #
      # @api private
      def targets_for(argv, root)
        return argv unless argv.empty?

        Dir.glob("#{root}/examples/*/").map { |d| d.chomp("/") }.select { |d| wired?(d) }
      end

      def wired?(dir) = !Dir.glob(File.join(dir, "**/*.hecksagon")).empty?

      # @api private
      def clean?(dir)
        puts "── #{File.basename(dir)}"
        failures = Bluebook::SmokeTest.call(dir)
        if failures.empty?
          puts "   clean — every declared command and report dispatched cleanly"
          return true
        end

        puts "   #{failures.size} failure(s)"
        failures.each { |f| puts "     #{f}" }
        false
      end
    end
  end
end
