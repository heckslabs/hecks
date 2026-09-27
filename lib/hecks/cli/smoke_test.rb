require_relative "../../hecks"
require_relative "../bluebook/smoke_test"

module Hecks
  module CLI
    # The command behind `bin/smoke_test` and `hecks smoke_test`: boots a real domain
    # and dispatches one synthesized call per declared command and report
    # (`Bluebook::SmokeTest`), printing every failure rather than the first.
    #
    # It needs a real `.hecksagon`: a bare `.bluebook` with nothing bound to an
    # adapter has nothing to run commands against. A failure may be a domain bug or
    # a value the synthesizer's naive choices (0, an empty list, "smoke-test") cannot
    # satisfy; the message underneath says which. Smoke-testing proves nothing
    # crashes, not that an answer is right.
    module SmokeTest
      module_function

      # Smoke-tests the domain `argv` names, or every wired domain under
      # `root/examples/`, and exits with the verdict.
      #
      # @param argv [Array<String>] an optional domain directory
      # @param root [String] the directory whose `examples/*` are tested when `argv`
      #   names no domain
      # @return [void]
      # @raise [SystemExit] always: 0 when clean, 1 with failures or no domain found
      def call(argv, root:)
        dir_arg = argv.first
        targets = dir_arg ? [dir_arg] : Dir.glob("#{root}/examples/*/").map { |d| d.chomp("/") }.select { |d| wired?(d) }
        abort "no wired example domains found (none of examples/* has a .hecksagon)" if targets.empty?

        ok = targets.reduce(true) { |all_ok, dir| clean?(dir) && all_ok }

        puts
        puts ok ? "Every declared command and report dispatched cleanly." : "SMOKE TEST FOUND PROBLEMS."
        exit(ok ? 0 : 1)
      end

      # Says whether `dir`, or something nested under it, is a bindable domain.
      #
      # @param dir [String] a directory to check
      # @return [Boolean] true if `dir` contains at least one `.hecksagon` file
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
