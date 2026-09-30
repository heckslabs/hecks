require_relative "../../hecks"
require_relative "../behaviors"

module Hecks
  module CLI
    # The command behind `hecks run_behaviors` and Custodian's `Operation.RunBehaviors`: runs
    # `.behaviors` files and reports pass, fail or error per test (docs/guides/behaviors.md).
    module Behaviors
      module_function

      # Runs one `.behaviors` file, or every one under a directory, and exits with the verdict.
      #
      # @param argv [Array<String>] the file or directory to run
      # @param program [String] the name the usage message calls this command by
      # @return [void]
      # @raise [SystemExit] always: 0 when every test passed, 1 when any failed, errored or did
      #   not parse
      def call(argv, program:)
        target = argv.first or abort "usage: #{program} <file.behaviors | directory>"
        abort "no such file or directory: #{target}" unless File.exist?(target)

        if File.directory?(target)
          sweep = Hecks::Behaviors.run_all(target)
          sweep.files.each { |file| report_file(file) }
          summary = sweep.summary
          puts
          puts "#{sweep.files_swept} file(s) swept — #{summary[:total]} test(s): " \
               "#{summary[:passed]} passed, #{summary[:failed]} failed, #{summary[:errored]} errored, " \
               "#{summary[:parse_errors]} file(s) failed to parse"
        else
          result = Hecks::Behaviors.run(target)
          report_file(result)
          summary = Hecks::Behaviors.summarize([result])
        end
        exit(bad?(summary) ? 1 : 0)
      end

      # @api private
      def report_file(result)
        puts result.path
        if result.parse_error
          puts "  PARSE ERROR — #{result.parse_error}"
          return
        end

        result.runs.each do |run|
          marker = { pass: "ok", fail: "FAIL", error: "ERROR" }.fetch(run.status)
          puts "  #{marker.ljust(5)} #{run.description}"
          puts "        #{run.message}" if run.message
        end
      end

      # @api private
      def bad?(summary)
        ((summary[:failed] || 0) + (summary[:errored] || 0) + (summary[:parse_errors] || 0)).positive?
      end
    end
  end
end
